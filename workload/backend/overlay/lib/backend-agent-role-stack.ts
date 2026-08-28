import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

/**
 * Props for the BackendAgentRoleStack.
 */
export interface BackendAgentRoleStackProps extends cdk.StackProps {
  /**
   * Override the platform space ARN (for testing without SSM lookups).
   * If not provided, the ARN is read from SSM at deploy time
   * (`/aiops-poc/agent-spaces/platform/arn`, written by sync-outputs.sh).
   */
  readonly platformSpaceArnOverride?: string;
}

/**
 * Creates the DevOps Agent monitor role in the BE account.
 *
 * This role is assumed by the DevOps Agent service when investigating
 * resources in the backend account on behalf of the platform Agent Space.
 *
 * Deployed AFTER the Agent Spaces stack exports the platform space ARN
 * to SSM (via sync-outputs.sh).
 */
export class BackendAgentRoleStack extends cdk.Stack {
  /** The DevOps Agent monitor role for the platform space. */
  public readonly agentRole: iam.Role;

  constructor(scope: Construct, id: string, props: BackendAgentRoleStackProps = {}) {
    super(scope, id, props);

    // Resolve the platform space ARN — either from override (tests) or SSM (deploy)
    const platformSpaceArn = props.platformSpaceArnOverride ??
      ssm.StringParameter.valueForStringParameter(
        this, '/aiops-poc/agent-spaces/platform/arn',
      );

    // The OPS account owns the agent space; its account id is the 5th
    // segment of the space ARN (arn:aws:aidevops:region:ACCOUNT:agentspace/id).
    const opsAccountId = cdk.Fn.select(4, cdk.Fn.split(':', platformSpaceArn));

    // ─────────────────────────────────────────────────────────────────────────
    // DevOpsAgentRole-Platform (cloud source role, console guidance shape)
    //
    // Trust: aidevops.amazonaws.com service principal with StringEquals
    //        conditions on aws:SourceAccount (OPS) and aws:SourceArn
    //        (the platform space ARN) — exactly the console guidance for
    //        connecting a secondary account.
    // Policies:
    //   - AWS managed: AIDevOpsAgentAccessPolicy (covers all agent reads,
    //     including Resource Explorer — no hand-rolled extras)
    //   - Inline: iam:CreateServiceLinkedRole on the Resource Explorer SLR
    // ─────────────────────────────────────────────────────────────────────────
    this.agentRole = new iam.Role(this, 'DevOpsAgentRolePlatform', {
      roleName: 'DevOpsAgentRole-Platform',
      description:
        'DevOps Agent monitor role for the platform space to investigate BE account resources',
      assumedBy: new iam.ServicePrincipal('aidevops.amazonaws.com', {
        conditions: {
          StringEquals: {
            'aws:SourceAccount': opsAccountId,
            'aws:SourceArn': platformSpaceArn,
          },
        },
      }),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsAgentAccessPolicy'),
      ],
    });

    // Inline policy (verbatim from the console guidance for connecting a
    // secondary account): allow creating the Resource Explorer
    // service-linked role so the agent can discover resources here.
    this.agentRole.addToPolicy(new iam.PolicyStatement({
      sid: 'AllowResourceExplorerServiceLinkedRole',
      effect: iam.Effect.ALLOW,
      actions: ['iam:CreateServiceLinkedRole'],
      resources: [
        `arn:aws:iam::${this.account}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer`,
      ],
    }));

    // ─────────────────────────────────────────────────────────────────────────
    // Outputs
    // ─────────────────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, 'AgentRoleArn', {
      value: this.agentRole.roleArn,
      description: 'ARN of the DevOpsAgentRole-Platform role',
      exportName: 'aiops-poc-devops-agent-role-platform-arn',
    });

    new cdk.CfnOutput(this, 'PlatformSpaceArn', {
      value: platformSpaceArn,
      description: 'Platform Agent Space ARN used for trust scoping',
      exportName: 'aiops-poc-platform-space-arn-be',
    });
  }
}
