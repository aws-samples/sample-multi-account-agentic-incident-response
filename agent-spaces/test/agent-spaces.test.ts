import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { AgentSpacesStack } from '../lib/agent-spaces-stack';

const BASE_PROPS = {
  env: { account: '333333333333', region: 'us-east-1' },
  frontendAccountId: '222222222222',
  backendAccountId: '111111111111',
};

describe('AgentSpacesStack — Phase 1 (no associations)', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new AgentSpacesStack(app, 'TestStack', {
      ...BASE_PROPS,
      enableAssociations: false,
    });
    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template.toJSON()).toBeDefined();
  });

  test('app-team Agent Space is created with correct name', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-app-team',
    });
  });

  test('platform Agent Space is created with correct name', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-platform',
    });
  });

  test('both spaces have operator app configuration', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-app-team',
      OperatorApp: Match.objectLike({
        Iam: Match.objectLike({
          OperatorAppRoleArn: Match.anyValue(),
        }),
      }),
    });
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-platform',
      OperatorApp: Match.objectLike({
        Iam: Match.objectLike({
          OperatorAppRoleArn: Match.anyValue(),
        }),
      }),
    });
  });

  test('OPS monitor role exists with AIDevOpsAgentAccessPolicy', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-devops-agent-monitor',
      ManagedPolicyArns: Match.arrayWith([
        Match.objectLike({
          'Fn::Join': Match.anyValue(),
        }),
      ]),
    });
  });

  test('monitor role attaches both managed policies (agent access + operator app)', () => {
    const roles = template.findResources('AWS::IAM::Role', {
      Properties: { RoleName: 'aiops-poc-devops-agent-monitor' },
    });
    const role = Object.values(roles)[0] as any;
    const managedArns = JSON.stringify(role.Properties.ManagedPolicyArns);
    expect(managedArns).toContain(':iam::aws:policy/AIDevOpsAgentAccessPolicy');
    expect(managedArns).toContain(':iam::aws:policy/AIDevOpsOperatorAppAccessPolicy');
  });

  test('monitor role trust allows sts:AssumeRole AND sts:TagSession (operator app tag scoping)', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-poc-devops-agent-monitor',
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Principal: { Service: 'aidevops.amazonaws.com' },
            Action: ['sts:AssumeRole', 'sts:TagSession'],
          }),
        ]),
      }),
    });
  });

  test('operator inline policy grants aidevops read/interact on both spaces', () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: 'aiops-poc-operator-aidevops-access',
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'OperatorSpaceAccess',
            Effect: 'Allow',
            Action: Match.arrayWith([
              'aidevops:Get*',
              'aidevops:List*',
              'aidevops:Describe*',
              'aidevops:CreateChat',
              'aidevops:SendMessage',
            ]),
            // Both space ARNs plus their /* sub-resources → 4 resource entries
            Resource: Match.arrayWith([
              Match.objectLike({ 'Fn::GetAtt': Match.anyValue() }),
            ]),
          }),
          Match.objectLike({
            Sid: 'OperatorAccountLevelAccess',
            Effect: 'Allow',
            Action: Match.arrayWith(['aidevops:ListAgentSpaces']),
            Resource: '*',
          }),
        ]),
      }),
    });
  });

  test('operator inline policy is attached to the monitor role', () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyName: 'aiops-poc-operator-aidevops-access',
      Roles: Match.arrayWith([Match.objectLike({ Ref: Match.anyValue() })]),
    });
  });

  test('SSM parameter for app-team space ARN is created', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/agent-spaces/app-team/arn',
      Type: 'String',
    });
  });

  test('SSM parameter for platform space ARN is created', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/agent-spaces/platform/arn',
      Type: 'String',
    });
  });

  test('SSM parameter for operator app URL is created', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/agent-spaces/app-team/operator-app-url',
      Type: 'String',
    });
  });

  test('no associations are created in phase 1', () => {
    const associations = template.findResources('AWS::DevOpsAgent::Association');
    expect(Object.keys(associations).length).toBe(0);
  });
});

describe('AgentSpacesStack — Phase 2 (with associations)', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new AgentSpacesStack(app, 'TestStack', {
      ...BASE_PROPS,
      enableAssociations: true,
    });
    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template.toJSON()).toBeDefined();
  });

  test('app-team to FE association is created', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::Association', {
      ServiceId: 'aws',
      Configuration: Match.objectLike({
        SourceAws: Match.objectLike({
          AccountId: '222222222222',
          AccountType: 'source',
          AssumableRoleArn:
            'arn:aws:iam::222222222222:role/DevOpsAgentRole-AppTeam',
        }),
      }),
    });
  });

  test('platform to BE association is created', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::Association', {
      ServiceId: 'aws',
      Configuration: Match.objectLike({
        SourceAws: Match.objectLike({
          AccountId: '111111111111',
          AccountType: 'source',
          AssumableRoleArn:
            'arn:aws:iam::111111111111:role/DevOpsAgentRole-Platform',
        }),
      }),
    });
  });

  test('exactly two associations are created', () => {
    const associations = template.findResources('AWS::DevOpsAgent::Association');
    expect(Object.keys(associations).length).toBe(2);
  });

  test('associations depend on their respective spaces', () => {
    // Verify DependsOn is set (associations depend on space creation)
    const associations = template.findResources('AWS::DevOpsAgent::Association');
    for (const key of Object.keys(associations)) {
      expect(associations[key].DependsOn).toBeDefined();
      expect(associations[key].DependsOn.length).toBeGreaterThan(0);
    }
  });

  test('spaces and SSM params still exist alongside associations', () => {
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-app-team',
    });
    template.hasResourceProperties('AWS::DevOpsAgent::AgentSpace', {
      Name: 'aiops-poc-platform',
    });
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/agent-spaces/app-team/arn',
    });
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/agent-spaces/platform/arn',
    });
  });
});
