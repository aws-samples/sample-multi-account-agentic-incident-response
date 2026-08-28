import * as cdk from 'aws-cdk-lib';
import * as bedrockagentcore from 'aws-cdk-lib/aws-bedrockagentcore';
import * as ecrAssets from 'aws-cdk-lib/aws-ecr-assets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Platform } from 'aws-cdk-lib/aws-ecr-assets';
import { Construct } from 'constructs';
import * as path from 'path';

export interface AgentsInfraStackProps extends cdk.StackProps {
  /** BE account id — needed for cross-account assume-role trust on task roles */
  backendAccountId: string;
  /** FE account id — needed for cross-account SNS subscription */
  frontendAccountId: string;
  /** Peer mode: devops | kb | both */
  peer: string;
  /** Whether agent skills are enabled */
  skillsEnabled: boolean;
  /**
   * Owning-team email for investigation escalations (KB agent → SNS).
   * Config variable in config/accounts.json (ops.escalationEmail) — the real
   * address never lives in committed code.
   */
  escalationEmail: string;
  /**
   * Bedrock model the fallback KB agent invokes, injected as MODEL_ID.
   * Config variable in config/accounts.json (bedrock.modelId) — resolved by
   * bin/app.ts so the stack never reads config itself.
   */
  modelId: string;
  /**
   * How eagerly the fallback KB agent escalates, injected as ESCALATION_MODE:
   * always | auto. Config variable in config/accounts.json (escalation.mode).
   */
  escalationMode: string;
}

export class AgentsInfraStack extends cdk.Stack {
  /** S3 bucket for investigation reports */
  public readonly reportBucket: s3.Bucket;
  /** S3 bucket for KB corpus data source */
  public readonly corpusBucket: s3.Bucket;
  /** IAM role trusting DevOps Agent service principal for remote-agent registration */
  public readonly remoteAgentRegistrationRole: iam.Role;
  /** Webhook bridge Lambda function */
  public readonly webhookBridgeFunction: lambda.Function;

  constructor(scope: Construct, id: string, props: AgentsInfraStackProps) {
    super(scope, id, props);

    const {
      backendAccountId, frontendAccountId, peer, skillsEnabled, escalationEmail,
      modelId, escalationMode,
    } = props;

    // ─────────────────────────────────────────────────────────────────────────
    // AgentCore Runtime execution roles
    //
    // These roles double as the runtime *execution* role (AgentCore pulls the
    // image and writes logs with it) and the *task* role the agent code uses
    // for AWS calls. Their names are pinned: the BE account's
    // aiops-backend-domain-read trust policy references these exact ARNs.
    // Trust follows the AgentCore Runtime trust policy contract
    // (bedrock-agentcore.amazonaws.com + SourceAccount/SourceArn conditions).
    // ─────────────────────────────────────────────────────────────────────────
    const agentCorePrincipal = new iam.ServicePrincipal(
      'bedrock-agentcore.amazonaws.com',
      {
        conditions: {
          StringEquals: { 'aws:SourceAccount': this.account },
          ArnLike: {
            'aws:SourceArn': `arn:aws:bedrock-agentcore:${this.region}:${this.account}:*`,
          },
        },
      },
    );

    /** Grants every AgentCore runtime role needs: ECR pull + CloudWatch Logs. */
    const addRuntimeBaselinePolicies = (role: iam.Role): void => {
      role.addToPolicy(
        new iam.PolicyStatement({
          sid: 'EcrImagePull',
          effect: iam.Effect.ALLOW,
          actions: ['ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer'],
          resources: [`arn:aws:ecr:${this.region}:${this.account}:repository/*`],
        }),
      );
      role.addToPolicy(
        new iam.PolicyStatement({
          sid: 'EcrAuthToken',
          effect: iam.Effect.ALLOW,
          actions: ['ecr:GetAuthorizationToken'],
          resources: ['*'],
        }),
      );
      role.addToPolicy(
        new iam.PolicyStatement({
          sid: 'CloudWatchLogs',
          effect: iam.Effect.ALLOW,
          actions: [
            'logs:CreateLogGroup',
            'logs:CreateLogStream',
            'logs:PutLogEvents',
            'logs:DescribeLogStreams',
            'logs:DescribeLogGroups',
          ],
          resources: [`arn:aws:logs:${this.region}:${this.account}:log-group:*`],
        }),
      );
      role.addToPolicy(
        new iam.PolicyStatement({
          sid: 'InvokeBedrockModels',
          effect: iam.Effect.ALLOW,
          actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
          resources: [
            `arn:aws:bedrock:*::foundation-model/*`,
            `arn:aws:bedrock:*:${this.account}:inference-profile/*`,
          ],
        }),
      );
    };

    // Role for the two fallback agents. Descoped to knowledge-only (2026-07):
    // the AssumeBackendDomainReadRole statement was removed — the fallback
    // agents lost their live telemetry tools (the DevOps Agent is the
    // live-telemetry layer), so they must not hold cross-account read.
    // The diagnostics MCP task role below keeps it (optional alternate).
    const agentTaskRole = new iam.Role(this, 'AgentTaskRole', {
      assumedBy: agentCorePrincipal,
      roleName: 'aiops-poc-agent-task-role',
    });
    addRuntimeBaselinePolicies(agentTaskRole);

    // Also allow reading SSM parameters in OPS
    agentTaskRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadOpsSSM',
        effect: iam.Effect.ALLOW,
        actions: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/aiops-poc/*`],
      }),
    );

    // Role for the diagnostics MCP server — same cross-account assume
    const mcpTaskRole = new iam.Role(this, 'McpTaskRole', {
      assumedBy: agentCorePrincipal,
      roleName: 'aiops-poc-mcp-task-role',
    });
    addRuntimeBaselinePolicies(mcpTaskRole);

    mcpTaskRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'AssumeBackendDomainReadRole',
        effect: iam.Effect.ALLOW,
        actions: ['sts:AssumeRole'],
        resources: [
          `arn:aws:iam::${backendAccountId}:role/aiops-backend-domain-read`,
        ],
      }),
    );

    mcpTaskRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadOpsSSM',
        effect: iam.Effect.ALLOW,
        actions: ['ssm:GetParameter', 'ssm:GetParameters', 'ssm:GetParametersByPath'],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/aiops-poc/*`],
      }),
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Bedrock Knowledge Base — corpus bucket + S3 data source + S3 Vectors
    // ─────────────────────────────────────────────────────────────────────────
    this.corpusBucket = new s3.Bucket(this, 'CorpusBucket', {
      bucketName: `aiops-poc-kb-corpus-${this.account}`,
      // Explicit at the resource level so the bucket does not depend on the
      // account-level S3 Block Public Access setting, which is managed
      // outside this stack and can be changed independently of it. Nothing
      // here needs public access: the corpus is read by the Bedrock
      // Knowledge Base service role and written by the BucketDeployment
      // Lambda, both over IAM.
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Upload the corpus files from agents/kb-corpus/
    new s3deploy.BucketDeployment(this, 'CorpusUpload', {
      sources: [
        s3deploy.Source.asset(path.resolve(__dirname, '../../../agents/kb-corpus')),
      ],
      destinationBucket: this.corpusBucket,
    });

    // S3 Vectors store: a dedicated vector bucket + index hold the embeddings.
    // titan-embed-text-v2 emits 1024-dimension float32 vectors; cosine distance.
    const vectorBucket = new cdk.CfnResource(this, 'KbVectorBucket', {
      type: 'AWS::S3Vectors::VectorBucket',
      properties: {
        VectorBucketName: `aiops-poc-kb-vectors-${this.account}`,
      },
    });

    const vectorIndex = new cdk.CfnResource(this, 'KbVectorIndex', {
      type: 'AWS::S3Vectors::Index',
      properties: {
        // NOTE: adding MetadataConfiguration forces a REPLACEMENT of the index,
        // and S3 Vectors cannot create a new index while one with the same name
        // still exists (409 AlreadyExists). Using a distinct name lets
        // CloudFormation create the new index, repoint the KB to its ARN, then
        // delete the old index. The prior index held no usable data (ingestion
        // failed), so this is safe.
        IndexName: 'aiops-poc-architecture-kb-index-v2',
        VectorBucketArn: vectorBucket.ref,
        DataType: 'float32',
        Dimension: 1024,
        DistanceMetric: 'cosine',
        // S3 Vectors enforces a 2048-byte limit on filterable metadata per
        // vector. Bedrock stores the full chunk text under AMAZON_BEDROCK_TEXT
        // (and source attribution under AMAZON_BEDROCK_METADATA), which easily
        // exceeds that limit and causes ingestion to reject every document.
        // Marking these keys as non-filterable exempts them from the size limit
        // while keeping them retrievable.
        MetadataConfiguration: {
          NonFilterableMetadataKeys: ['AMAZON_BEDROCK_TEXT', 'AMAZON_BEDROCK_METADATA'],
        },
      },
    });
    vectorIndex.addDependency(vectorBucket);

    // KB execution role for Bedrock to access the corpus bucket + vector store
    const kbRole = new iam.Role(this, 'KbExecutionRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      roleName: 'aiops-poc-kb-execution-role',
    });

    this.corpusBucket.grantRead(kbRole);

    // Allow Bedrock to invoke the embedding model
    kbRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'InvokeEmbeddingModel',
        effect: iam.Effect.ALLOW,
        actions: ['bedrock:InvokeModel'],
        resources: [
          `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`,
        ],
      }),
    );

    // Allow Bedrock to read/write vectors in the S3 Vectors store
    kbRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'AccessS3VectorsStore',
        effect: iam.Effect.ALLOW,
        actions: [
          's3vectors:GetVectorBucket',
          's3vectors:GetIndex',
          's3vectors:PutVectors',
          's3vectors:GetVectors',
          's3vectors:ListVectors',
          's3vectors:QueryVectors',
          's3vectors:DeleteVectors',
        ],
        resources: [
          vectorBucket.ref,
          `${vectorBucket.ref}/index/*`,
        ],
      }),
    );

    // CfnKnowledgeBase — S3 data source with S3 Vectors embedding store
    const knowledgeBase = new cdk.CfnResource(this, 'BedrockKnowledgeBase', {
      type: 'AWS::Bedrock::KnowledgeBase',
      properties: {
        Name: 'aiops-poc-architecture-kb',
        Description: 'PetAdoptions architecture and scenario knowledge for fallback KB agent',
        RoleArn: kbRole.roleArn,
        KnowledgeBaseConfiguration: {
          Type: 'VECTOR',
          VectorKnowledgeBaseConfiguration: {
            EmbeddingModelArn: `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`,
            EmbeddingModelConfiguration: {
              BedrockEmbeddingModelConfiguration: {
                Dimensions: 1024,
                EmbeddingDataType: 'FLOAT32',
              },
            },
          },
        },
        StorageConfiguration: {
          Type: 'S3_VECTORS',
          S3VectorsConfiguration: {
            VectorBucketArn: vectorBucket.ref,
            IndexArn: vectorIndex.getAtt('IndexArn'),
          },
        },
      },
    });
    knowledgeBase.addDependency(vectorIndex);
    // The KB is a raw L1 resource that only references the role's ARN, so it
    // would otherwise create before the role's inline policy (which grants the
    // s3vectors + embedding-model permissions) is attached, causing a 403 on
    // s3vectors:QueryVectors. Depend on the whole role construct (incl. its
    // default policy) to guarantee the grants exist first.
    knowledgeBase.node.addDependency(kbRole);

    // Data source pointing to the corpus bucket (full bucket — no inclusion prefix)
    new cdk.CfnResource(this, 'KbDataSource', {
      type: 'AWS::Bedrock::DataSource',
      properties: {
        KnowledgeBaseId: knowledgeBase.getAtt('KnowledgeBaseId'),
        Name: 'aiops-poc-corpus-s3',
        Description: 'S3 corpus for the architecture KB',
        DataSourceConfiguration: {
          Type: 'S3',
          S3Configuration: {
            BucketArn: this.corpusBucket.bucketArn,
          },
        },
      },
    });

    // Grant the agent task role permission to query the KB
    agentTaskRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'QueryBedrockKB',
        effect: iam.Effect.ALLOW,
        actions: [
          'bedrock:Retrieve',
          'bedrock:RetrieveAndGenerate',
        ],
        resources: ['*'], // Scoped at deploy time via resource policy if needed
      }),
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Report store S3 bucket
    // ─────────────────────────────────────────────────────────────────────────
    this.reportBucket = new s3.Bucket(this, 'ReportBucket', {
      bucketName: `aiops-poc-reports-${this.account}`,
      // See CorpusBucket: explicit at the resource level rather than relying
      // on the account-level setting. Reports are written by the agent task
      // role over IAM (grantWrite below) and read by operators through the
      // console — no public access path is required.
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Allow agent task role to write reports
    this.reportBucket.grantWrite(agentTaskRole);

    // ─────────────────────────────────────────────────────────────────────────
    // Escalation topic — KB agent → SNS → owning-team email
    //
    // The KB agent's escalate_to_owner_team tool publishes an investigation
    // summary here so a human on the service-owning team gets an email.
    // ─────────────────────────────────────────────────────────────────────────
    const escalationTopic = new sns.Topic(this, 'EscalationTopic', {
      topicName: 'aiops-poc-escalations',
      displayName: 'AI-Ops PoC — investigation escalations',
    });

    // Email subscription — requires a one-time manual confirmation click in
    // the recipient's inbox after deploy. The address is a config variable in
    // config/accounts.json (ops.escalationEmail, git-ignored).
    escalationTopic.addSubscription(
      new snsSubscriptions.EmailSubscription(escalationEmail),
    );

    // sns:Publish scoped to ONLY this topic ARN. This is the single
    // deliberate write-action exception to the otherwise read-only fallback
    // agents: it can only notify humans (email via this topic) and cannot
    // mutate any workload resource.
    escalationTopic.grantPublish(agentTaskRole);

    // ─────────────────────────────────────────────────────────────────────────
    // Bedrock AgentCore runtimes — fallback agents (MCP) + diagnostics MCP
    //
    // Managed HTTPS endpoints with SigV4 auth (service: bedrock-agentcore).
    // All three runtimes now serve the MCP contract: container listens on
    // 0.0.0.0:8000 at /mcp (stateless streamable HTTP; the platform generates
    // Mcp-Session-Id headers and load balances across microVMs, so servers
    // must not track sessions).
    // The two fallback agents are dual-protocol containers: SERVE_PROTOCOL
    // selects MCP (primary, single `investigate` tool) or A2A (alternate:
    // 0.0.0.0:9000, agent card at /.well-known/agent-card.json, health at
    // GET /ping — kept for demonstration). Images must be ARM64 and live in
    // ECR (the CDK asset repo qualifies).
    // ─────────────────────────────────────────────────────────────────────────
    // The two Python agents share the `agents/shared` package and `agents/skills`
    // catalog, so their Docker build context is the `agents/` directory and the
    // Dockerfile is referenced relative to it. The diagnostics MCP server is
    // self-contained and builds from its own directory.
    const agentsContextDir = path.resolve(__dirname, '../../../agents');

    const devopsAgentImage = new ecrAssets.DockerImageAsset(this, 'BackendDevopsAgentImage', {
      directory: agentsContextDir,
      file: 'backend-agent/Dockerfile',
      platform: Platform.LINUX_ARM64,
    });

    const kbAgentImage = new ecrAssets.DockerImageAsset(this, 'BackendKbAgentImage', {
      directory: agentsContextDir,
      file: 'kb-agent/Dockerfile',
      platform: Platform.LINUX_ARM64,
    });

    const mcpImage = new ecrAssets.DockerImageAsset(this, 'DiagnosticsMcpImage', {
      directory: path.resolve(__dirname, '../../../mcp-servers/backend-diagnostics'),
      platform: Platform.LINUX_ARM64,
    });

    // Common env for agent containers. AgentCore injects credentials for the
    // runtime role; region is passed explicitly because the containers default
    // to a hardcoded region otherwise.
    // BE_ACCOUNT_ID was removed with the knowledge-only descope: only the
    // (now unused) telemetry code paths read it, and both readers carry
    // in-code fallbacks.
    const commonAgentEnv: Record<string, string> = {
      AWS_REGION: this.region,
      AWS_DEFAULT_REGION: this.region,
      REPORT_BUCKET: this.reportBucket.bucketName,
    };

    const devopsRuntime = new bedrockagentcore.CfnRuntime(this, 'BackendDevopsAgentRuntime', {
      // AgentRuntimeName disallows hyphens — underscores only.
      agentRuntimeName: 'backend_devops_agent',
      description: 'Fallback runbook-consultation agent — documented causes/checks from Agent Skills, no live telemetry (Strands, MCP `investigate` tool)',
      agentRuntimeArtifact: {
        containerConfiguration: { containerUri: devopsAgentImage.imageUri },
      },
      roleArn: agentTaskRole.roleArn,
      networkConfiguration: { networkMode: 'PUBLIC' },
      protocolConfiguration: 'MCP',
      // protocolConfiguration: 'A2A', // ALTERNATE variant — flip together with SERVE_PROTOCOL
      environmentVariables: {
        ...commonAgentEnv,
        SERVE_PROTOCOL: 'MCP',
        SKILLS_DIR: '/app/agents/skills',
        SKILLS_ENABLED: String(skillsEnabled),
      },
    });
    devopsRuntime.node.addDependency(agentTaskRole);

    const kbRuntime = new bedrockagentcore.CfnRuntime(this, 'BackendKbAgentRuntime', {
      agentRuntimeName: 'backend_kb_agent',
      description: 'Fallback KB-grounded consultation agent — documented causes/checks with citations + SNS escalation, no live telemetry (Strands + Bedrock KB, MCP `investigate` tool)',
      agentRuntimeArtifact: {
        containerConfiguration: { containerUri: kbAgentImage.imageUri },
      },
      roleArn: agentTaskRole.roleArn,
      networkConfiguration: { networkMode: 'PUBLIC' },
      protocolConfiguration: 'MCP',
      // protocolConfiguration: 'A2A', // ALTERNATE variant — flip together with SERVE_PROTOCOL
      environmentVariables: {
        ...commonAgentEnv,
        SERVE_PROTOCOL: 'MCP',
        // Cross-region inference profile — the bare foundation-model ID and
        // the sonnet-4 profile are rejected in this account. Sourced from
        // config/accounts.json (bedrock.modelId), whose template default is
        // this PoC's verified profile.
        MODEL_ID: modelId,
        KNOWLEDGE_BASE_ID: knowledgeBase.getAtt('KnowledgeBaseId').toString(),
        ESCALATION_TOPIC_ARN: escalationTopic.topicArn,
        // 'always' is the demo-eager default: the agent escalates every
        // investigation so the email reliably arrives. Values: always | auto.
        // Sourced from config/accounts.json (escalation.mode).
        ESCALATION_MODE: escalationMode,
      },
    });
    kbRuntime.node.addDependency(agentTaskRole);

    const mcpRuntime = new bedrockagentcore.CfnRuntime(this, 'DiagnosticsMcpRuntime', {
      agentRuntimeName: 'diagnostics_mcp',
      description: 'Deterministic backend diagnostics tools (streamable-HTTP MCP)',
      agentRuntimeArtifact: {
        containerConfiguration: { containerUri: mcpImage.imageUri },
      },
      roleArn: mcpTaskRole.roleArn,
      networkConfiguration: { networkMode: 'PUBLIC' },
      protocolConfiguration: 'MCP',
      environmentVariables: {
        AWS_REGION: this.region,
        AWS_DEFAULT_REGION: this.region,
        // Parameterize the BE account the diagnostics tools assume-role into,
        // sourced from config/accounts.json (backend.accountId) — never a
        // hardcoded literal, so a new deployment targets its own BE account.
        BE_ACCOUNT_ID: backendAccountId,
      },
    });
    mcpRuntime.node.addDependency(mcpTaskRole);

    // SSM exports — remote-agent registration points at these ARNs
    const runtimeParams: Array<[string, bedrockagentcore.CfnRuntime]> = [
      ['backend-devops-agent', devopsRuntime],
      ['backend-kb-agent', kbRuntime],
      ['diagnostics-mcp', mcpRuntime],
    ];

    for (const [name, runtime] of runtimeParams) {
      new ssm.StringParameter(this, `SsmRuntimeArn-${name}`, {
        parameterName: `/aiops-poc/agents/${name}/runtime-arn`,
        stringValue: runtime.attrAgentRuntimeArn,
        description: `AgentCore runtime ARN for ${name}`,
      });
      new ssm.StringParameter(this, `SsmRuntimeId-${name}`, {
        parameterName: `/aiops-poc/agents/${name}/runtime-id`,
        stringValue: runtime.attrAgentRuntimeId,
        description: `AgentCore runtime id for ${name}`,
      });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SSM switches
    // ─────────────────────────────────────────────────────────────────────────
    new ssm.StringParameter(this, 'SsmPeer', {
      parameterName: '/aiops-poc/peer',
      stringValue: peer,
      description: 'Fallback peer selection: devops | kb | both',
    });

    new ssm.StringParameter(this, 'SsmSkillsEnabled', {
      parameterName: '/aiops-poc/skills-enabled',
      stringValue: String(skillsEnabled),
      description: 'Whether agent skills are enabled for fallback agents',
    });

    // Escalation topic ARN for scripts/operators (the KB agent gets it via env)
    new ssm.StringParameter(this, 'SsmEscalationTopicArn', {
      parameterName: '/aiops-poc/escalation-topic-arn',
      stringValue: escalationTopic.topicArn,
      description: 'SNS topic ARN for KB-agent investigation escalations',
    });

    // KB id for containers that resolve it via SSM instead of env
    new ssm.StringParameter(this, 'SsmKnowledgeBaseId', {
      parameterName: '/aiops-poc/kb/knowledge-base-id',
      stringValue: knowledgeBase.getAtt('KnowledgeBaseId').toString(),
      description: 'Bedrock Knowledge Base id for the KB agent',
    });

    // ─────────────────────────────────────────────────────────────────────────
    // IAM role trusting DevOps Agent service principal for remote-agent registration
    // ─────────────────────────────────────────────────────────────────────────
    this.remoteAgentRegistrationRole = new iam.Role(this, 'RemoteAgentRegistrationRole', {
      roleName: 'aiops-poc-remote-agent-registration',
      assumedBy: new iam.CompositePrincipal(
        // RegisterService validates the trust policy carries SourceAccount /
        // SourceArn conditions (confused-deputy protection) — without them
        // registration fails with "Role validation failed ... The trust
        // policy doesn't include either SourceArn or SourceAccount".
        new iam.ServicePrincipal('bedrock.amazonaws.com', {
          conditions: {
            StringEquals: { 'aws:SourceAccount': this.account },
          },
        }),
        // AWS DevOps Agent service principal (per AWS docs the principal is
        // `aidevops.amazonaws.com`; the `devopsagent`/`aidevops` service uses
        // the `arn:aws:aidevops:...:agentspace/*` namespace).
        new iam.ServicePrincipal('aidevops.amazonaws.com', {
          conditions: {
            StringEquals: { 'aws:SourceAccount': this.account },
            ArnLike: {
              'aws:SourceArn': `arn:aws:aidevops:${this.region}:${this.account}:*`,
            },
          },
        }),
      ),
      description:
        'Trust role for DevOps Agent capability providers: fallback A2A agents (AgentCore) and the platform space remote MCP endpoint',
    });

    this.remoteAgentRegistrationRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'InvokeAgentCoreEndpoints',
        effect: iam.Effect.ALLOW,
        actions: [
          'bedrock-agentcore:InvokeAgentRuntime',
          'bedrock:InvokeAgent',
        ],
        // ⚠ Resource wildcard — NARROW BEFORE PRODUCTION USE.
        //
        // The three runtime ARNs this stack creates are available here as
        // tokens (devopsRuntime/kbRuntime/mcpRuntime .attrAgentRuntimeArn),
        // so a narrower list is synthesizable. It is deliberately NOT used
        // yet, for two reasons:
        //
        //   1. `bedrock-agentcore:InvokeAgentRuntime` is authorized against
        //      the qualified endpoint ARN (<runtimeArn>/runtime-endpoint/*),
        //      not only the bare runtime ARN, so a list built from
        //      attrAgentRuntimeArn alone can deny at invoke time — a failure
        //      that surfaces only at runtime, never at synth or in tests.
        //   2. `bedrock:InvokeAgent` targets Bedrock agents that are not
        //      created by this stack, so their ARNs are not known here.
        //
        // Before production use, replace with the explicit list plus the
        // `/runtime-endpoint/*` suffix, and validate with a live invoke of
        // each runtime. Same treatment as the InvokeDevopsAgentRemoteMcp
        // statement below.
        resources: ['*'],
      }),
    );

    // Space-to-space MCP link (scripts/register-platform-space-mcp.sh):
    // the app-team space calls the platform space's remote MCP endpoint
    // (connect.aidevops /mcp) with SigV4 service "aidevops" through this
    // role, routed by an X-Agent-Space-Id customHeader. Action set mirrors
    // the operator monitor role's read/interact safety net (investigations
    // are backlog tasks); the exact set the endpoint authorizes can only
    // be validated once the MCP registration gate clears.
    this.remoteAgentRegistrationRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'InvokeDevopsAgentRemoteMcp',
        effect: iam.Effect.ALLOW,
        actions: [
          // ⚠ Service-scoped wildcards — NARROW BEFORE PRODUCTION USE.
          // `Get*`, `List*` and `Describe*` are read-only prefixes, but they
          // grant every current AND future matching aidevops action, so the
          // effective permission set grows silently as the service adds APIs.
          // They are used here only because the exact action set the remote
          // MCP endpoint authorizes cannot be enumerated until the MCP
          // registration gate clears (see the note above). Once the required
          // calls are known, replace these three prefixes with that explicit
          // list. The resource is already scoped to this account's
          // `agentspace/*`, so the wildcard is on actions only.
          'aidevops:Get*',
          'aidevops:List*',
          'aidevops:Describe*',
          'aidevops:CreateChat',
          'aidevops:SendMessage',
          'aidevops:CreateBacklogTask',
          'aidevops:UpdateBacklogTask',
        ],
        resources: [
          `arn:aws:aidevops:${this.region}:${this.account}:agentspace/*`,
        ],
      }),
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Webhook bridge: SNS (FE+BE incidents) → Lambda → HMAC webhook
    // NOTE: In an enterprise deployment, the webhook target would be
    // ServiceNow's inbound webhook API (same HMAC payload format, different
    // URL stored in the secret). The Lambda POSTs to ServiceNow's webhook
    // endpoint instead of the DevOps Agent generic webhook.
    // ─────────────────────────────────────────────────────────────────────────

    // Cross-account incident topic ARNs (deterministic names from design)
    const beIncidentsTopicArn = `arn:aws:sns:${this.region}:${backendAccountId}:aiops-poc-incidents`;
    const feIncidentsTopicArn = `arn:aws:sns:${this.region}:${frontendAccountId}:aiops-poc-fe-incidents`;

    // Import topics by ARN for cross-account subscription
    const beIncidentsTopic = sns.Topic.fromTopicArn(this, 'BeIncidentsTopic', beIncidentsTopicArn);
    const feIncidentsTopic = sns.Topic.fromTopicArn(this, 'FeIncidentsTopic', feIncidentsTopicArn);

    // DLQ for failed webhook deliveries
    const webhookBridgeDlq = new sqs.Queue(this, 'WebhookBridgeDlq', {
      queueName: 'aiops-poc-webhook-bridge-dlq',
      retentionPeriod: cdk.Duration.days(14),
    });

    // Secrets Manager secret (placeholder — populated by set-webhook-secret.sh
    // after the DevOps Agent Operator Web App creates the webhook)
    const webhookCredentials = new secretsmanager.Secret(this, 'WebhookCredentials', {
      secretName: 'aiops-poc/webhook-credentials',
      description:
        'Webhook URL + HMAC secret for the app-team generic webhook. ' +
        'Populated by set-webhook-secret.sh after Agent Space webhook creation.',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ webhook_url: '', hmac_secret: '' }),
        generateStringKey: '_placeholder',
      },
    });

    // Platform-space webhook credentials (dual-path routing). Raw infra
    // alarms (aiops-poc-be-infra-*) are routed by the bridge to the PLATFORM
    // DevOps Agent space — the infra-owning space with live BE telemetry —
    // so it runs its own live RCA while the app-team space stays focused on
    // customer-facing golden signals. Populated by
    // scripts/register-webhook.sh --space platform.
    const platformWebhookCredentials = new secretsmanager.Secret(this, 'PlatformWebhookCredentials', {
      secretName: 'aiops-poc/platform-webhook-credentials',
      description:
        'Webhook URL + HMAC secret for the platform (infra-owning) generic webhook. ' +
        'Populated by scripts/register-webhook.sh --space platform.',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ webhook_url: '', hmac_secret: '' }),
        generateStringKey: '_placeholder',
      },
    });

    // Lambda function for the webhook bridge
    this.webhookBridgeFunction = new lambda.Function(this, 'WebhookBridgeFunction', {
      functionName: 'aiops-poc-webhook-bridge',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'handler.handler',
      // `exclude` keeps test-run leftovers out of the deployed zip. Without it
      // running the handler test suite drops `__pycache__/` and `.pytest_cache/`
      // into the asset directory, which then ship inside the function bundle and
      // change the asset hash with no source change. `tests/` is excluded too —
      // handler.py imports nothing from it, so it is dead weight at runtime.
      code: lambda.Code.fromAsset(path.resolve(__dirname, '../lambda/webhook-bridge'), {
        exclude: ['__pycache__', '*.pyc', '*.pyo', '.pytest_cache', 'tests'],
      }),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        SECRET_NAME: webhookCredentials.secretName,
        PLATFORM_SECRET_NAME: platformWebhookCredentials.secretName,
        DLQ_URL: webhookBridgeDlq.queueUrl,
      },
      deadLetterQueue: webhookBridgeDlq,
      logRetention: logs.RetentionDays.ONE_WEEK,
    });

    // Grant Lambda read access to both webhook credentials secrets
    webhookCredentials.grantRead(this.webhookBridgeFunction);
    platformWebhookCredentials.grantRead(this.webhookBridgeFunction);

    // Grant Lambda send-message to DLQ
    webhookBridgeDlq.grantSendMessages(this.webhookBridgeFunction);

    // Allow SNS from both accounts to invoke the Lambda
    this.webhookBridgeFunction.addPermission('AllowBeSnsTrigger', {
      principal: new iam.ServicePrincipal('sns.amazonaws.com'),
      sourceArn: beIncidentsTopicArn,
    });

    this.webhookBridgeFunction.addPermission('AllowFeSnsTrigger', {
      principal: new iam.ServicePrincipal('sns.amazonaws.com'),
      sourceArn: feIncidentsTopicArn,
    });

    // Cross-account SNS subscriptions
    beIncidentsTopic.addSubscription(
      new snsSubscriptions.LambdaSubscription(this.webhookBridgeFunction),
    );
    feIncidentsTopic.addSubscription(
      new snsSubscriptions.LambdaSubscription(this.webhookBridgeFunction),
    );

    // SSM parameter for the webhook bridge function name (used by scripts)
    new ssm.StringParameter(this, 'SsmWebhookBridgeFunction', {
      parameterName: '/aiops-poc/webhook-bridge-function',
      stringValue: this.webhookBridgeFunction.functionName,
      description: 'Webhook bridge Lambda function name',
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Outputs
    // ─────────────────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'ReportBucketName', {
      value: this.reportBucket.bucketName,
      exportName: 'AiopsReportBucketName',
    });

    new cdk.CfnOutput(this, 'CorpusBucketName', {
      value: this.corpusBucket.bucketName,
      exportName: 'AiopsCorpusBucketName',
    });

    new cdk.CfnOutput(this, 'AgentTaskRoleArn', {
      value: agentTaskRole.roleArn,
      exportName: 'AiopsAgentTaskRoleArn',
    });

    new cdk.CfnOutput(this, 'McpTaskRoleArn', {
      value: mcpTaskRole.roleArn,
      exportName: 'AiopsMcpTaskRoleArn',
    });

    new cdk.CfnOutput(this, 'RemoteAgentRegistrationRoleArn', {
      value: this.remoteAgentRegistrationRole.roleArn,
      exportName: 'AiopsRemoteAgentRegistrationRoleArn',
    });

    new cdk.CfnOutput(this, 'WebhookBridgeFunctionName', {
      value: this.webhookBridgeFunction.functionName,
      exportName: 'AiopsWebhookBridgeFunctionName',
    });

    new cdk.CfnOutput(this, 'WebhookBridgeDlqUrl', {
      value: webhookBridgeDlq.queueUrl,
      exportName: 'AiopsWebhookBridgeDlqUrl',
    });

    new cdk.CfnOutput(this, 'BackendDevopsAgentRuntimeArn', {
      value: devopsRuntime.attrAgentRuntimeArn,
      exportName: 'AiopsBackendDevopsAgentRuntimeArn',
    });

    new cdk.CfnOutput(this, 'BackendKbAgentRuntimeArn', {
      value: kbRuntime.attrAgentRuntimeArn,
      exportName: 'AiopsBackendKbAgentRuntimeArn',
    });

    new cdk.CfnOutput(this, 'DiagnosticsMcpRuntimeArn', {
      value: mcpRuntime.attrAgentRuntimeArn,
      exportName: 'AiopsDiagnosticsMcpRuntimeArn',
    });

    new cdk.CfnOutput(this, 'EscalationTopicArn', {
      value: escalationTopic.topicArn,
      exportName: 'AiopsEscalationTopicArn',
    });
  }
}
