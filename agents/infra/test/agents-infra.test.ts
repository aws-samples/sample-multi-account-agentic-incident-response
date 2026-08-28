import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { AgentsInfraStack, AgentsInfraStackProps } from '../lib/agents-infra-stack';

describe('AgentsInfraStack', () => {
  let template: Template;
  // Single source of truth for the fixture inputs: assertions read the expected
  // account IDs and region from here instead of restating them.
  let stackProps: AgentsInfraStackProps & { env: cdk.Environment };

  beforeAll(() => {
    const app = new cdk.App();
    stackProps = {
      env: { account: '333333333333', region: 'us-east-1' },
      backendAccountId: '111111111111',
      frontendAccountId: '222222222222',
      peer: 'both',
      skillsEnabled: true,
      escalationEmail: 'ops-team@example.com',
      modelId: 'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
      escalationMode: 'always',
    };
    const stack = new AgentsInfraStack(app, 'TestStack', stackProps);
    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    // If we get here, synth succeeded
    expect(template.toJSON()).toBeDefined();
  });

  test('report bucket exists', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: Match.stringLikeRegexp('aiops-poc-reports-'),
    });
  });

  test('corpus bucket exists', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: Match.stringLikeRegexp('aiops-poc-kb-corpus-'),
    });
  });

  test('SSM parameter /aiops-poc/peer exists with correct value', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/peer',
      Value: 'both',
      Type: 'String',
    });
  });

  test('SSM parameter /aiops-poc/skills-enabled exists with correct value', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/skills-enabled',
      Value: 'true',
      Type: 'String',
    });
  });

  test('only the MCP task role holds cross-account assume-role to BE (agents descoped to knowledge-only)', () => {
    const resources = template.findResources('AWS::IAM::Policy', {
      Properties: {
        PolicyDocument: {
          Statement: Match.arrayWith([
            Match.objectLike({
              Sid: 'AssumeBackendDomainReadRole',
              Action: 'sts:AssumeRole',
              Resource: 'arn:aws:iam::111111111111:role/aiops-backend-domain-read',
            }),
          ]),
        },
      },
    });
    // Exactly one policy: the diagnostics MCP task role (optional alternate).
    // The fallback-agent task role lost the statement in the knowledge-only
    // descope — they have no live telemetry and must not hold x-acct read.
    const keys = Object.keys(resources);
    expect(keys.length).toBe(1);
    expect(JSON.stringify(resources[keys[0]].Properties.Roles)).toContain('McpTaskRole');
    expect(JSON.stringify(resources[keys[0]].Properties.Roles)).not.toContain('AgentTaskRole');
  });

  test('Bedrock Knowledge Base resource is present', () => {
    template.hasResource('AWS::Bedrock::KnowledgeBase', {});
  });

  test('Bedrock Data Source resource is present', () => {
    template.hasResource('AWS::Bedrock::DataSource', {});
  });

  test('S3 Vectors index marks Bedrock text metadata keys as non-filterable', () => {
    template.hasResourceProperties('AWS::S3Vectors::Index', {
      IndexName: 'aiops-poc-architecture-kb-index-v2',
      MetadataConfiguration: {
        NonFilterableMetadataKeys: Match.arrayWith([
          'AMAZON_BEDROCK_TEXT',
          'AMAZON_BEDROCK_METADATA',
        ]),
      },
    });
  });

  test('remote-agent registration trust role exists with correct principals', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-remote-agent-registration',
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: {
              Service: Match.anyValue(),
            },
          }),
        ]),
      },
    });
  });

  test('trust role allows bedrock.amazonaws.com and aidevops.amazonaws.com', () => {
    // Find the registration role and verify both service principals
    const roles = template.findResources('AWS::IAM::Role', {
      Properties: {
        RoleName: 'aiops-poc-remote-agent-registration',
      },
    });
    const roleKeys = Object.keys(roles);
    expect(roleKeys.length).toBe(1);

    const trustPolicy = roles[roleKeys[0]].Properties.AssumeRolePolicyDocument;
    const statements = trustPolicy.Statement;

    // Collect all service principals from all statements
    const principals: string[] = [];
    for (const stmt of statements) {
      if (stmt.Principal?.Service) {
        const svc = stmt.Principal.Service;
        if (Array.isArray(svc)) {
          principals.push(...svc);
        } else {
          principals.push(svc);
        }
      }
    }
    expect(principals).toContain('bedrock.amazonaws.com');
    expect(principals).toContain('aidevops.amazonaws.com');

    // Confused-deputy protection: RegisterService validates the trust
    // policy carries SourceAccount / SourceArn conditions.
    for (const stmt of statements) {
      const svc = stmt.Principal?.Service;
      const services: string[] = Array.isArray(svc) ? svc : svc ? [svc] : [];
      if (services.includes('bedrock.amazonaws.com')) {
        expect(stmt.Condition?.StringEquals?.['aws:SourceAccount']).toBeDefined();
      }
      if (services.includes('aidevops.amazonaws.com')) {
        expect(stmt.Condition?.StringEquals?.['aws:SourceAccount']).toBeDefined();
        expect(stmt.Condition?.ArnLike?.['aws:SourceArn']).toBeDefined();
      }
    }
  });

  // ─────────────────────────────────────────────────────────────────────────
  // AgentCore runtime tests
  // ─────────────────────────────────────────────────────────────────────────

  test('no ECS or VPC resources remain after AgentCore migration', () => {
    expect(Object.keys(template.findResources('AWS::ECS::Cluster')).length).toBe(0);
    expect(Object.keys(template.findResources('AWS::ECS::Service')).length).toBe(0);
    expect(Object.keys(template.findResources('AWS::EC2::VPC')).length).toBe(0);
  });

  test('three AgentCore runtimes are defined', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    expect(Object.keys(runtimes).length).toBe(3);
  });

  test('all three runtimes serve MCP (fallback agents switched from A2A)', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    const byProtocol: Record<string, string[]> = {};
    for (const key of Object.keys(runtimes)) {
      const props = runtimes[key].Properties;
      byProtocol[props.ProtocolConfiguration] ??= [];
      byProtocol[props.ProtocolConfiguration].push(props.AgentRuntimeName);
    }
    expect(byProtocol['MCP']?.sort()).toEqual([
      'backend_devops_agent',
      'backend_kb_agent',
      'diagnostics_mcp',
    ]);
    expect(byProtocol['A2A']).toBeUndefined();
  });

  test('fallback agent runtimes pin SERVE_PROTOCOL=MCP', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    for (const key of Object.keys(runtimes)) {
      const props = runtimes[key].Properties;
      if (['backend_devops_agent', 'backend_kb_agent'].includes(props.AgentRuntimeName)) {
        expect(props.EnvironmentVariables.SERVE_PROTOCOL).toBe('MCP');
      }
    }
  });

  test('fallback agent runtimes no longer receive BE_ACCOUNT_ID (knowledge-only descope)', () => {
    // Scoped to the two knowledge-only fallback agents. The diagnostics_mcp
    // runtime DOES receive BE_ACCOUNT_ID (parameterized from
    // config/accounts.json → backend.accountId) because its tools assume-role
    // into the BE account to read live state — see the DiagnosticsMcpRuntime
    // env in agents-infra-stack.ts.
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    for (const key of Object.keys(runtimes)) {
      const props = runtimes[key].Properties;
      if (['backend_devops_agent', 'backend_kb_agent'].includes(props.AgentRuntimeName)) {
        expect(props.EnvironmentVariables?.BE_ACCOUNT_ID).toBeUndefined();
      }
    }
  });

  test('diagnostics MCP runtime receives BE_ACCOUNT_ID and region from the config-derived props', () => {
    // Every environment variable the diagnostics MCP requires at startup has a
    // populator here: BE_ACCOUNT_ID from backend.accountId (via props), and both
    // region variables from the stack's own region (Requirement 5.5, 4.2).
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    const mcp = Object.values(runtimes).find(
      (r: any) => r.Properties.AgentRuntimeName === 'diagnostics_mcp',
    ) as any;
    expect(mcp).toBeDefined();
    const envVars = mcp.Properties.EnvironmentVariables;
    expect(envVars.BE_ACCOUNT_ID).toBe(stackProps.backendAccountId);
    expect(envVars.AWS_REGION).toBe(stackProps.env.region);
    expect(envVars.AWS_DEFAULT_REGION).toBe(stackProps.env.region);
  });

  test('fallback runtime descriptions state the knowledge-only role', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    for (const key of Object.keys(runtimes)) {
      const props = runtimes[key].Properties;
      if (props.AgentRuntimeName === 'backend_devops_agent') {
        expect(props.Description).toContain('runbook-consultation');
        expect(props.Description).toContain('no live telemetry');
      }
      if (props.AgentRuntimeName === 'backend_kb_agent') {
        expect(props.Description).toContain('KB-grounded consultation');
        expect(props.Description).toContain('no live telemetry');
      }
    }
  });

  test('all runtimes use PUBLIC network mode and a container image URI', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    for (const key of Object.keys(runtimes)) {
      const props = runtimes[key].Properties;
      expect(props.NetworkConfiguration).toEqual({ NetworkMode: 'PUBLIC' });
      expect(props.AgentRuntimeArtifact.ContainerConfiguration.ContainerUri).toBeDefined();
      expect(props.RoleArn).toBeDefined();
    }
  });

  test('agent task role keeps its pinned name and trusts bedrock-agentcore', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-agent-task-role',
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: { Service: 'bedrock-agentcore.amazonaws.com' },
            Condition: Match.objectLike({
              StringEquals: { 'aws:SourceAccount': '333333333333' },
            }),
          }),
        ]),
      },
    });
  });

  test('MCP task role keeps its pinned name and trusts bedrock-agentcore', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-mcp-task-role',
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: { Service: 'bedrock-agentcore.amazonaws.com' },
            Condition: Match.objectLike({
              StringEquals: { 'aws:SourceAccount': '333333333333' },
            }),
          }),
        ]),
      },
    });
  });

  test('runtime roles have ECR pull, logs, and Bedrock model invoke permissions', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    const matching = Object.keys(policies).filter((key) => {
      const statements = policies[key].Properties.PolicyDocument.Statement;
      const sids = statements.map((s: any) => s.Sid);
      return (
        sids.includes('EcrImagePull') &&
        sids.includes('EcrAuthToken') &&
        sids.includes('CloudWatchLogs') &&
        sids.includes('InvokeBedrockModels')
      );
    });
    // Both the agent task role and the MCP task role carry the baseline grants
    expect(matching.length).toBeGreaterThanOrEqual(2);
  });

  test('SSM runtime-arn parameters exist for all three runtimes', () => {
    for (const name of ['backend-devops-agent', 'backend-kb-agent', 'diagnostics-mcp']) {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: `/aiops-poc/agents/${name}/runtime-arn`,
        Type: 'String',
      });
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: `/aiops-poc/agents/${name}/runtime-id`,
        Type: 'String',
      });
    }
  });

  test('KB execution role trusts bedrock.amazonaws.com', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-kb-execution-role',
      AssumeRolePolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Principal: {
              Service: 'bedrock.amazonaws.com',
            },
          }),
        ]),
      },
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Webhook bridge tests
  // ─────────────────────────────────────────────────────────────────────────

  test('webhook bridge Lambda function exists with Python 3.11', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'aiops-poc-webhook-bridge',
      Runtime: 'python3.11',
      Handler: 'handler.handler',
    });
  });

  test('webhook bridge DLQ (SQS queue) exists', () => {
    template.hasResourceProperties('AWS::SQS::Queue', {
      QueueName: 'aiops-poc-webhook-bridge-dlq',
    });
  });

  test('webhook bridge Lambda has SNS invoke permission for BE topic', () => {
    template.hasResourceProperties('AWS::Lambda::Permission', {
      Action: 'lambda:InvokeFunction',
      Principal: 'sns.amazonaws.com',
      SourceArn: 'arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents',
    });
  });

  test('webhook bridge Lambda has SNS invoke permission for FE topic', () => {
    template.hasResourceProperties('AWS::Lambda::Permission', {
      Action: 'lambda:InvokeFunction',
      Principal: 'sns.amazonaws.com',
      SourceArn: 'arn:aws:sns:us-east-1:222222222222:aiops-poc-fe-incidents',
    });
  });

  test('webhook bridge has two lambda SNS subscriptions', () => {
    const subscriptions = template.findResources('AWS::SNS::Subscription');
    const lambdaSubs = Object.keys(subscriptions).filter(
      (key) => subscriptions[key].Properties.Protocol === 'lambda',
    );
    expect(lambdaSubs.length).toBe(2);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Escalation topic tests (KB agent → SNS → owning-team email)
  // ─────────────────────────────────────────────────────────────────────────

  test('escalation SNS topic exists', () => {
    template.hasResourceProperties('AWS::SNS::Topic', {
      TopicName: 'aiops-poc-escalations',
      DisplayName: 'AI-Ops PoC — investigation escalations',
    });
  });

  test('escalation topic has an email subscription to the configured address', () => {
    template.hasResourceProperties('AWS::SNS::Subscription', {
      Protocol: 'email',
      Endpoint: 'ops-team@example.com',
    });
  });

  test('kb runtime carries ESCALATION_TOPIC_ARN and ESCALATION_MODE env vars', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    const kb = Object.values(runtimes).find(
      (r: any) => r.Properties.AgentRuntimeName === 'backend_kb_agent',
    ) as any;
    expect(kb).toBeDefined();
    const envVars = kb.Properties.EnvironmentVariables;
    // Topic ARN is a CFN Ref to the created topic
    expect(envVars.ESCALATION_TOPIC_ARN).toBeDefined();
    expect(envVars.ESCALATION_MODE).toBe('always');
    // The devops agent runtime must NOT get the escalation env (KB-only feature)
    const devops = Object.values(runtimes).find(
      (r: any) => r.Properties.AgentRuntimeName === 'backend_devops_agent',
    ) as any;
    expect(devops.Properties.EnvironmentVariables.ESCALATION_TOPIC_ARN).toBeUndefined();
  });

  test('kb runtime carries the configured MODEL_ID (bedrock.modelId) verbatim', () => {
    const runtimes = template.findResources('AWS::BedrockAgentCore::Runtime');
    const kb = Object.values(runtimes).find(
      (r: any) => r.Properties.AgentRuntimeName === 'backend_kb_agent',
    ) as any;
    expect(kb.Properties.EnvironmentVariables.MODEL_ID).toBe(
      'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
    );
  });

  test('agent task role has sns:Publish scoped to the escalation topic only', () => {
    const policies = template.findResources('AWS::IAM::Policy');
    const publishStatements: any[] = [];
    for (const key of Object.keys(policies)) {
      for (const stmt of policies[key].Properties.PolicyDocument.Statement) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        if (actions.includes('sns:Publish')) {
          publishStatements.push({ policyKey: key, stmt, roles: policies[key].Properties.Roles });
        }
      }
    }
    // Exactly one sns:Publish grant in the stack
    expect(publishStatements.length).toBe(1);
    const { stmt, roles } = publishStatements[0];
    // Scoped to the escalation topic Ref, not a wildcard
    expect(stmt.Resource.Ref).toBeDefined();
    expect(stmt.Resource.Ref).toContain('EscalationTopic');
    // Attached to the agent task role
    expect(JSON.stringify(roles)).toContain('AgentTaskRole');
  });

  test('SSM parameter /aiops-poc/escalation-topic-arn exists', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/escalation-topic-arn',
      Type: 'String',
    });
  });

  test('Secrets Manager secret for webhook credentials exists', () => {
    template.hasResourceProperties('AWS::SecretsManager::Secret', {
      Name: 'aiops-poc/webhook-credentials',
    });
  });

  test('Secrets Manager secret for the platform webhook credentials exists', () => {
    // Dual-path routing: be-infra-* alarms page the platform space via this
    // second secret. Same placeholder shape as the app-team secret.
    template.hasResourceProperties('AWS::SecretsManager::Secret', {
      Name: 'aiops-poc/platform-webhook-credentials',
    });
  });

  test('SSM parameter /aiops-poc/webhook-bridge-function exists', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/webhook-bridge-function',
      Type: 'String',
    });
  });

  test('webhook bridge Lambda has environment variables for secret and DLQ', () => {
    const lambdas = template.findResources('AWS::Lambda::Function', {
      Properties: Match.objectLike({
        FunctionName: 'aiops-poc-webhook-bridge',
      }),
    });
    const keys = Object.keys(lambdas);
    expect(keys.length).toBe(1);
    const envVars = lambdas[keys[0]].Properties.Environment.Variables;
    // SECRET_NAME is a reference to the created secret (CDK resolves via Fn::Join)
    expect(envVars.SECRET_NAME).toBeDefined();
    // PLATFORM_SECRET_NAME references the platform webhook secret (dual-path)
    expect(envVars.PLATFORM_SECRET_NAME).toBeDefined();
    // DLQ_URL is a reference to the SQS queue URL
    expect(envVars.DLQ_URL).toBeDefined();
  });

  test('webhook bridge Lambda has read access to BOTH webhook secrets', () => {
    // The lambda must be granted secretsmanager:GetSecretValue on the
    // app-team AND platform secrets for dual-path routing (+ fallback).
    const policies = template.findResources('AWS::IAM::Policy');
    const getSecretResources: string[] = [];
    for (const key of Object.keys(policies)) {
      for (const stmt of policies[key].Properties.PolicyDocument.Statement) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        if (actions.includes('secretsmanager:GetSecretValue')) {
          getSecretResources.push(JSON.stringify(stmt.Resource));
        }
      }
    }
    const joined = getSecretResources.join(' ');
    expect(joined).toContain('WebhookCredentials');
    expect(joined).toContain('PlatformWebhookCredentials');
  });
});
