import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { BackendAgentRoleStack } from '../lib/backend-agent-role-stack';

describe('BackendAgentRoleStack', () => {
  const PLATFORM_SPACE_ARN =
    'arn:aws:devopsagent:us-east-1:333333333333:space/aiops-poc-platform';

  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new BackendAgentRoleStack(app, 'TestBackendAgentRoleStack', {
      env: { account: '111111111111', region: 'us-east-1' },
      platformSpaceArnOverride: PLATFORM_SPACE_ARN,
    });
    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template).toBeDefined();
  });

  test('role exists with the name DevOpsAgentRole-Platform', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'DevOpsAgentRole-Platform',
    });
  });

  test('trust policy principal is aidevops.amazonaws.com', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'DevOpsAgentRole-Platform',
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: Match.objectLike({
              Service: 'aidevops.amazonaws.com',
            }),
            Action: 'sts:AssumeRole',
          }),
        ]),
      }),
    });
  });

  test('trust condition matches console guidance: SourceAccount (OPS) + SourceArn (space)', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'DevOpsAgentRole-Platform',
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Condition: Match.objectLike({
              StringEquals: {
                // 5th ARN segment of PLATFORM_SPACE_ARN — the OPS account id
                'aws:SourceAccount': '333333333333',
                'aws:SourceArn': PLATFORM_SPACE_ARN,
              },
            }),
          }),
        ]),
      }),
    });
  });

  test('role has AIDevOpsAgentAccessPolicy managed policy attached', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'DevOpsAgentRole-Platform',
      ManagedPolicyArns: Match.arrayWith([
        Match.objectLike({
          'Fn::Join': Match.arrayWith([
            Match.arrayWith([
              Match.stringLikeRegexp('arn:'),
              Match.stringLikeRegexp(':iam::aws:policy/AIDevOpsAgentAccessPolicy'),
            ]),
          ]),
        }),
      ]),
    });
  });

  test('inline policy is the verbatim Resource Explorer SLR statement from console guidance', () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'AllowResourceExplorerServiceLinkedRole',
            Effect: 'Allow',
            Action: 'iam:CreateServiceLinkedRole',
            Resource:
              'arn:aws:iam::111111111111:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer',
          }),
        ]),
      }),
    });
  });

  test('no hand-rolled resource-explorer-2 permissions remain (managed policy covers reads)', () => {
    const templateJson = JSON.stringify(template.toJSON());
    expect(templateJson).not.toContain('resource-explorer-2:*');
  });

  test('trust does NOT allow the entire OPS or BE account root', () => {
    const templateJson = JSON.stringify(template.toJSON());
    expect(templateJson).not.toContain('"arn:aws:iam::333333333333:root"');
    expect(templateJson).not.toContain('"arn:aws:iam::111111111111:root"');
  });

  test('exports the agent role ARN', () => {
    template.hasOutput('AgentRoleArn', {
      Export: { Name: 'aiops-poc-devops-agent-role-platform-arn' },
    });
  });

  test('exports the platform space ARN', () => {
    template.hasOutput('PlatformSpaceArn', {
      Value: PLATFORM_SPACE_ARN,
      Export: { Name: 'aiops-poc-platform-space-arn-be' },
    });
  });
});
