import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as devopsagent from 'aws-cdk-lib/aws-devopsagent';
import { Construct } from 'constructs';

export interface AgentSpacesStackProps extends cdk.StackProps {
  /** FE account id — associated with the app-team space */
  frontendAccountId: string;
  /** BE account id — associated with the platform space */
  backendAccountId: string;
  /**
   * Whether to create source associations (phase 2).
   * Requires the DevOps Agent monitor roles in FE/BE accounts to exist first.
   * Set via CDK context: -c ENABLE_ASSOCIATIONS=false|true. The cdk.json
   * default is `true` — the steady state, since the associations exist in the
   * deployed stack and a `false` default would make every deploy delete them.
   * Only phase 1 of a fresh deployment opts out.
   */
  enableAssociations: boolean;
  /**
   * Federation identifier for the Operator Web App (config:
   * accounts.json → operator.federationIdentifier).
   *
   * Neither the DevOps Agent API nor CloudFormation exposes this setting
   * (verified against the service model and AWS::DevOpsAgent::AgentSpace),
   * so it CANNOT be applied here — it must be set once per space in the
   * console (space → Operator Access tab). The stack only surfaces the
   * configured value as an output so scripts/README can echo the manual
   * step; deployments never touch (and can never clobber) the value set
   * manually in the console.
   */
  operatorFederationIdentifier?: string;
}

export class AgentSpacesStack extends cdk.Stack {
  /** App-team Agent Space */
  public readonly appTeamSpace: devopsagent.CfnAgentSpace;
  /** Platform Agent Space */
  public readonly platformSpace: devopsagent.CfnAgentSpace;

  constructor(scope: Construct, id: string, props: AgentSpacesStackProps) {
    super(scope, id, props);

    const { frontendAccountId, backendAccountId, enableAssociations } = props;

    // ─────────────────────────────────────────────────────────────────────────
    // OPS monitor role — allows operators in OPS to access both Agent Spaces.
    //
    // Mirrors the console-created operator-app role
    // (DevOpsAgentRole-WebappAdmin-*, the working reference):
    //   - AWS managed AIDevOpsOperatorAppAccessPolicy — the operator web app
    //     policy; it scopes aidevops actions to
    //     agentspace/${aws:PrincipalTag/AgentSpaceId}, which is why the trust
    //     policy must also allow sts:TagSession (the service tags the session
    //     with the space id it is federating into).
    //   - AWS managed AIDevOpsAgentAccessPolicy — asset/knowledge reads.
    // ─────────────────────────────────────────────────────────────────────────
    // The DevOps Agent service assumes this operator-app role. Its trust policy
    // must allow the aidevops.amazonaws.com service principal, scoped to this
    // account and any agent space ARN in the account (confused-deputy
    // protection; unlike the console reference role, this single role serves
    // BOTH spaces, hence the ArnLike wildcard instead of a fixed space ARN).
    const monitorRole = new iam.Role(this, 'OpsMonitorRole', {
      roleName: 'aiops-poc-devops-agent-monitor',
      assumedBy: new iam.ServicePrincipal('aidevops.amazonaws.com', {
        conditions: {
          StringEquals: {
            'aws:SourceAccount': this.account,
          },
          ArnLike: {
            'aws:SourceArn': `arn:aws:aidevops:${this.region}:${this.account}:agentspace/*`,
          },
        },
      }),
      description:
        'OPS account role for accessing both DevOps Agent Agent Spaces (app-team and platform)',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsAgentAccessPolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsOperatorAppAccessPolicy'),
      ],
    });

    // The console reference role allows sts:AssumeRole + sts:TagSession in a
    // single trust statement. CDK's ServicePrincipal only emits sts:AssumeRole,
    // so override the action list on the generated statement.
    const cfnMonitorRole = monitorRole.node.defaultChild as iam.CfnRole;
    cfnMonitorRole.addPropertyOverride(
      'AssumeRolePolicyDocument.Statement.0.Action',
      ['sts:AssumeRole', 'sts:TagSession'],
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Agent Spaces
    // ─────────────────────────────────────────────────────────────────────────

    // App-team space — first responder, associated to FE
    this.appTeamSpace = new devopsagent.CfnAgentSpace(this, 'AppTeamSpace', {
      name: 'aiops-poc-app-team',
      description:
        'First responder: owns every incident, triages the app domain (FE), delegates to platform or fallback',
      operatorApp: {
        iam: {
          operatorAppRoleArn: monitorRole.roleArn,
        },
      },
    });

    // Platform space — investigates the platform on delegation from app-team
    this.platformSpace = new devopsagent.CfnAgentSpace(this, 'PlatformSpace', {
      name: 'aiops-poc-platform',
      description:
        'Platform agent: investigates backend services (ECS, Aurora, DynamoDB, SQS) on delegation from app-team',
      operatorApp: {
        iam: {
          operatorAppRoleArn: monitorRole.roleArn,
        },
      },
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Operator access inline policy — kept as a tag-independent safety net.
    //
    // The managed AIDevOpsOperatorAppAccessPolicy above scopes everything to
    // ${aws:PrincipalTag/AgentSpaceId}, which only resolves when the service
    // tags the federated session. This inline policy grants the same
    // read + interact API set (ListBacklogTasks, CreateChat, SendMessage, ...)
    // scoped explicitly to our two space ARNs, so operator access keeps
    // working even for untagged sessions (this is what fixed the original
    // "not authorized to perform: aidevops:ListBacklogTasks" web app error,
    // and the user's manually repaired access depends on it — do not remove).
    // ─────────────────────────────────────────────────────────────────────────
    monitorRole.attachInlinePolicy(
      new iam.Policy(this, 'OperatorAidevopsAccess', {
        policyName: 'aiops-poc-operator-aidevops-access',
        statements: [
          // Read + interact actions scoped to the two spaces (and their
          // sub-resources: backlog tasks, chats, executions, journals, ...)
          new iam.PolicyStatement({
            sid: 'OperatorSpaceAccess',
            actions: [
              'aidevops:Get*',
              'aidevops:List*',
              'aidevops:Describe*',
              'aidevops:CreateChat',
              'aidevops:SendMessage',
              'aidevops:CreateBacklogTask',
              'aidevops:UpdateBacklogTask',
              'aidevops:UpdateGoal',
              'aidevops:UpdateRecommendation',
            ],
            resources: [
              this.appTeamSpace.attrArn,
              `${this.appTeamSpace.attrArn}/*`,
              this.platformSpace.attrArn,
              `${this.platformSpace.attrArn}/*`,
            ],
          }),
          // Account-level operations that are not resource-scoped
          new iam.PolicyStatement({
            sid: 'OperatorAccountLevelAccess',
            actions: [
              'aidevops:ListAgentSpaces',
              'aidevops:GetAccountUsage',
              'aidevops:ListServices',
              'aidevops:GetService',
            ],
            resources: ['*'],
          }),
        ],
      }),
    );

    // ─────────────────────────────────────────────────────────────────────────
    // SSM exports — space ARNs for cross-account sync-outputs
    // ─────────────────────────────────────────────────────────────────────────
    new ssm.StringParameter(this, 'SsmAppTeamSpaceArn', {
      parameterName: '/aiops-poc/agent-spaces/app-team/arn',
      stringValue: this.appTeamSpace.attrArn,
      description: 'ARN of the app-team DevOps Agent Space',
    });

    new ssm.StringParameter(this, 'SsmPlatformSpaceArn', {
      parameterName: '/aiops-poc/agent-spaces/platform/arn',
      stringValue: this.platformSpace.attrArn,
      description: 'ARN of the platform DevOps Agent Space',
    });

    // Operator app URL is derived from the space — store for convenience
    // Format: https://connect.aidevops.{region}.api.aws/spaces/{spaceId}/operator
    new ssm.StringParameter(this, 'SsmAppTeamOperatorUrl', {
      parameterName: '/aiops-poc/agent-spaces/app-team/operator-app-url',
      stringValue: cdk.Fn.join('', [
        'https://connect.aidevops.',
        this.region,
        '.api.aws/spaces/',
        this.appTeamSpace.attrAgentSpaceId,
        '/operator',
      ]),
      description: 'Operator web app URL for the app-team space',
    });

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 2: Source associations (gated on ENABLE_ASSOCIATIONS context flag,
    // default `true` in cdk.json). These require the DevOps Agent monitor roles
    // in FE/BE to already exist, so phase 1 of a fresh deployment opts out with
    // -c ENABLE_ASSOCIATIONS=false.
    // ─────────────────────────────────────────────────────────────────────────
    if (enableAssociations) {
      // App-team → FE account association
      const appTeamAssociation = new devopsagent.CfnAssociation(
        this,
        'AppTeamFEAssociation',
        {
          agentSpaceId: this.appTeamSpace.attrAgentSpaceId,
          // For SourceAws configurations the serviceId must be the literal 'aws'
          serviceId: 'aws',
          configuration: {
            sourceAws: {
              accountId: frontendAccountId,
              accountType: 'source',
              assumableRoleArn: `arn:aws:iam::${frontendAccountId}:role/DevOpsAgentRole-AppTeam`,
            },
          },
        },
      );
      appTeamAssociation.addDependency(this.appTeamSpace);

      // Platform → BE account association
      const platformAssociation = new devopsagent.CfnAssociation(
        this,
        'PlatformBEAssociation',
        {
          agentSpaceId: this.platformSpace.attrAgentSpaceId,
          // For SourceAws configurations the serviceId must be the literal 'aws'
          serviceId: 'aws',
          configuration: {
            sourceAws: {
              accountId: backendAccountId,
              accountType: 'source',
              assumableRoleArn: `arn:aws:iam::${backendAccountId}:role/DevOpsAgentRole-Platform`,
            },
          },
        },
      );
      platformAssociation.addDependency(this.platformSpace);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Outputs
    // ─────────────────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'AppTeamSpaceArn', {
      value: this.appTeamSpace.attrArn,
      exportName: 'AiopsAppTeamSpaceArn',
    });

    new cdk.CfnOutput(this, 'PlatformSpaceArn', {
      value: this.platformSpace.attrArn,
      exportName: 'AiopsPlatformSpaceArn',
    });

    new cdk.CfnOutput(this, 'AppTeamSpaceId', {
      value: this.appTeamSpace.attrAgentSpaceId,
      exportName: 'AiopsAppTeamSpaceId',
    });

    new cdk.CfnOutput(this, 'PlatformSpaceId', {
      value: this.platformSpace.attrAgentSpaceId,
      exportName: 'AiopsPlatformSpaceId',
    });

    new cdk.CfnOutput(this, 'OpsMonitorRoleArn', {
      value: monitorRole.roleArn,
      exportName: 'AiopsOpsMonitorRoleArn',
    });

    // Informational only — the federation identifier cannot be set via the
    // API or CloudFormation; it must be entered once per space in the console
    // (Operator Access tab). See agent-spaces/README.md.
    if (props.operatorFederationIdentifier) {
      new cdk.CfnOutput(this, 'OperatorFederationIdentifier', {
        value: props.operatorFederationIdentifier,
        description:
          'Federation identifier to set MANUALLY in the console Operator Access tab of each space (not settable via API/CFN)',
      });
    }
  }
}
