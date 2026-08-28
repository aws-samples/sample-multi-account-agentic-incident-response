import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

/**
 * Configuration for the FrontendAgentRoleStack.
 */
export interface FrontendAgentRoleStackProps extends cdk.StackProps {
  /**
   * SSM parameter name holding the app-team Agent Space ARN.
   * Default: /aiops-poc/agent-spaces/app-team/arn
   */
  readonly spaceArnSsmParam?: string;

  /**
   * Override for the space ARN (for testing without SSM lookups).
   * When set, bypasses SSM parameter resolution.
   */
  readonly spaceArnOverride?: string;
}

/**
 * FrontendAgentRoleStack creates the DevOps Agent monitor role in the FE
 * account. This stack is deployed AFTER Agent Spaces exist in OPS and
 * space ARNs have been synced to FE via sync-outputs.sh.
 *
 * The role is assumed by the DevOps Agent service principal, scoped to
 * the app-team Agent Space ARN via an aws:SourceArn condition.
 */
export class FrontendAgentRoleStack extends cdk.Stack {
  /** The IAM role ARN for the DevOps Agent monitor role. */
  public readonly roleArn: string;

  constructor(scope: Construct, id: string, props: FrontendAgentRoleStackProps = {}) {
    super(scope, id, props);

    const spaceArnSsmParam = props.spaceArnSsmParam ??
      '/aiops-poc/agent-spaces/app-team/arn';

    // Resolve the app-team space ARN: use override for testing, otherwise SSM
    let spaceArn: string;
    if (props.spaceArnOverride) {
      spaceArn = props.spaceArnOverride;
    } else {
      spaceArn = ssm.StringParameter.valueForStringParameter(this, spaceArnSsmParam);
    }

    // The OPS account owns the agent space; its account id is the 5th
    // segment of the space ARN (arn:aws:aidevops:region:ACCOUNT:agentspace/id).
    // Deriving it avoids a second config plumbing path and keeps the trust
    // policy exactly aligned with the console guidance for cloud sources:
    //   StringEquals: aws:SourceAccount = <ops account>
    //                 aws:SourceArn     = <this space's ARN>
    const opsAccountId = cdk.Fn.select(4, cdk.Fn.split(':', spaceArn));

    // --- DevOps Agent monitor role (cloud source role, console guidance shape) ---
    const role = new iam.Role(this, 'DevOpsAgentRole', {
      roleName: 'DevOpsAgentRole-AppTeam',
      assumedBy: new iam.ServicePrincipal('aidevops.amazonaws.com', {
        conditions: {
          StringEquals: {
            'aws:SourceAccount': opsAccountId,
            'aws:SourceArn': spaceArn,
          },
        },
      }),
      description: 'DevOps Agent monitor role for the app-team space (FE account)',
    });

    // Managed policy: AIDevOpsAgentAccessPolicy (per console guidance — the
    // managed policy already contains every read permission the agent needs,
    // including Resource Explorer read access; do not hand-roll extras).
    role.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsAgentAccessPolicy'),
    );

    // Inline policy (verbatim from the console guidance for connecting a
    // secondary account): allow creating the Resource Explorer
    // service-linked role so the agent can discover resources here.
    role.addToPolicy(new iam.PolicyStatement({
      sid: 'AllowResourceExplorerServiceLinkedRole',
      effect: iam.Effect.ALLOW,
      actions: ['iam:CreateServiceLinkedRole'],
      resources: [
        `arn:aws:iam::${this.account}:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer`,
      ],
    }));

    this.roleArn = role.roleArn;

    // --- Stack outputs ---
    new cdk.CfnOutput(this, 'DevOpsAgentRoleArn', {
      value: role.roleArn,
      description: 'DevOps Agent monitor role ARN (app-team, FE account)',
      exportName: 'aiops-poc-fe-devops-agent-role-arn',
    });

    new cdk.CfnOutput(this, 'AppTeamSpaceArn', {
      value: spaceArn,
      description: 'App-team Agent Space ARN used in trust condition',
      exportName: 'aiops-poc-fe-app-team-space-arn',
    });
  }
}
