import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { FrontendAgentRoleStack } from '../lib/frontend-agent-role-stack';

describe('FrontendAgentRoleStack', () => {
  const SPACE_ARN = 'arn:aws:devopsagent:us-east-1:333333333333:space/app-team';
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new FrontendAgentRoleStack(app, 'TestFrontendAgentRoleStack', {
      env: { account: '222222222222', region: 'us-east-1' },
      spaceArnOverride: SPACE_ARN,
    });
    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template).toBeDefined();
  });

  test('creates IAM role with correct name', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'DevOpsAgentRole-AppTeam',
    });
  });

  test('role trusts aidevops.amazonaws.com service principal', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: {
              Service: 'aidevops.amazonaws.com',
            },
            Action: 'sts:AssumeRole',
          }),
        ]),
      }),
    });
  });

  test('trust condition matches console guidance: SourceAccount (OPS) + SourceArn (space)', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Condition: {
              StringEquals: {
                // 5th ARN segment of SPACE_ARN — the OPS account id
                'aws:SourceAccount': '333333333333',
                'aws:SourceArn': SPACE_ARN,
              },
            },
          }),
        ]),
      }),
    });
  });

  test('AIDevOpsAgentAccessPolicy managed policy is attached', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
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
            Action: 'iam:CreateServiceLinkedRole',
            Effect: 'Allow',
            Resource:
              'arn:aws:iam::222222222222:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer',
          }),
        ]),
      }),
    });
  });

  test('no hand-rolled resource-explorer-2 permissions remain (managed policy covers reads)', () => {
    const templateJson = JSON.stringify(template.toJSON());
    expect(templateJson).not.toContain('resource-explorer-2:*');
  });

  test('exports role ARN', () => {
    template.hasOutput('DevOpsAgentRoleArn', {
      Export: { Name: 'aiops-poc-fe-devops-agent-role-arn' },
    });
  });

  test('exports space ARN', () => {
    template.hasOutput('AppTeamSpaceArn', {
      Value: SPACE_ARN,
      Export: { Name: 'aiops-poc-fe-app-team-space-arn' },
    });
  });
});
