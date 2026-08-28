import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { BackendOverlayStack } from '../lib/backend-overlay-stack';

describe('BackendOverlayStack', () => {
  let app: cdk.App;
  let stack: BackendOverlayStack;
  let template: Template;

  beforeAll(() => {
    app = new cdk.App();

    stack = new BackendOverlayStack(app, 'TestBackendOverlayStack', {
      env: { account: '111111111111', region: 'us-east-1' },
      opsAccountId: '333333333333',
      frontendAccountId: '222222222222',
      clusterNameOverride: 'Services',
    });

    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template).toBeDefined();
  });

  test('exports the ECS cluster name', () => {
    template.hasOutput('EcsClusterName', {
      Value: 'Services',
      Export: { Name: 'aiops-poc-ecs-cluster-name' },
    });
  });

  test('exports the ECS cluster ARN', () => {
    template.hasOutput('EcsClusterArn', {
      Value: {
        'Fn::Join': ['', [
          'arn:',
          { Ref: 'AWS::Partition' },
          ':ecs:us-east-1:111111111111:cluster/Services',
        ]],
      },
      Export: { Name: 'aiops-poc-ecs-cluster-arn' },
    });
  });

  test('exports the OPS account ID', () => {
    template.hasOutput('OpsAccountId', {
      Value: '333333333333',
      Export: { Name: 'aiops-poc-ops-account-id' },
    });
  });

  test('OPS account ID is accessible as property', () => {
    expect(stack.opsAccountId).toBe('333333333333');
  });

  test('upstream resources are exposed with cluster name', () => {
    expect(stack.upstream.clusterName).toBe('Services');
  });

  test('service URLs are discovered from SSM (deploy-time tokens)', () => {
    expect(stack.upstream.payForAdoptionUrl).toBeDefined();
    expect(stack.upstream.petSearchUrl).toBeDefined();
    expect(stack.upstream.petListAdoptionsUrl).toBeDefined();
    expect(stack.upstream.petStatusUpdaterUrl).toBeDefined();
  });

  test('uses SSM parameters for service URL discovery', () => {
    // Names follow the upstream's restructured SSM contract:
    // paymentapiurl (NOT payforadoptionurl) and queueurl (NOT sqsqueueurl).
    const templateJson = JSON.stringify(template.toJSON());
    expect(templateJson).toContain('/petstore/paymentapiurl');
    expect(templateJson).toContain('/petstore/searchapiurl');
    expect(templateJson).toContain('/petstore/petlistadoptionsurl');
    expect(templateJson).toContain('/petstore/updateadoptionstatusurl');
  });

  test('stack is independently deployable with BE account', () => {
    expect(stack.account).toBe('111111111111');
    expect(stack.region).toBe('us-east-1');
  });

  // ================================================================
  // SSM Exports tests (/aiops-poc/workload/*)
  // ================================================================
  describe('SSM Exports', () => {
    test('SSM parameter /aiops-poc/workload/ecs-cluster exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/ecs-cluster',
        Value: 'Services',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/pay-for-adoption-url exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/pay-for-adoption-url',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/pet-search-url exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/pet-search-url',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/pet-list-adoptions-url exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/pet-list-adoptions-url',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/status-updater-url exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/status-updater-url',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/ddb-table-name exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/ddb-table-name',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/sqs-queue-url exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/sqs-queue-url',
        Type: 'String',
      });
    });

    test('SSM parameter /aiops-poc/workload/petsite-privatelink-service-name exists', () => {
      template.hasResourceProperties('AWS::SSM::Parameter', {
        Name: '/aiops-poc/workload/petsite-privatelink-service-name',
        Type: 'String',
      });
    });

    test('all eight SSM exports are created', () => {
      template.resourceCountIs('AWS::SSM::Parameter', 8);
    });
  });

  // ================================================================
  // PrivateLink (FE → BE private connectivity) tests
  // ================================================================
  describe('PrivateLink endpoint service', () => {
    test('creates an internal network load balancer', () => {
      template.hasResourceProperties('AWS::ElasticLoadBalancingV2::LoadBalancer', {
        Type: 'network',
        Scheme: 'internal',
      });
    });

    test('creates four ALB-type target groups on port 80', () => {
      const tgs = Object.values(
        template.findResources('AWS::ElasticLoadBalancingV2::TargetGroup'),
      ).filter((tg: any) => tg.Properties?.TargetType === 'alb');
      expect(tgs.length).toBe(4);
      for (const tg of tgs) {
        expect((tg as any).Properties.Port).toBe(80);
        expect((tg as any).Properties.Protocol).toBe('TCP');
        // Each target group forwards to exactly one upstream internal ALB
        expect((tg as any).Properties.Targets).toHaveLength(1);
        expect((tg as any).Properties.Targets[0].Port).toBe(80);
      }
    });

    test('NLB listens on 80 (petsearch), 8080 (petlistadoption), 8081 (petfood) and 8082 (payforadoption)', () => {
      template.hasResourceProperties('AWS::ElasticLoadBalancingV2::Listener', {
        Port: 80,
        Protocol: 'TCP',
      });
      template.hasResourceProperties('AWS::ElasticLoadBalancingV2::Listener', {
        Port: 8080,
        Protocol: 'TCP',
      });
      template.hasResourceProperties('AWS::ElasticLoadBalancingV2::Listener', {
        Port: 8081,
        Protocol: 'TCP',
      });
      template.hasResourceProperties('AWS::ElasticLoadBalancingV2::Listener', {
        Port: 8082,
        Protocol: 'TCP',
      });
    });

    test('endpoint service does not require acceptance', () => {
      template.hasResourceProperties('AWS::EC2::VPCEndpointService', {
        AcceptanceRequired: false,
      });
    });

    test('endpoint service allows the FE account principal', () => {
      template.hasResourceProperties('AWS::EC2::VPCEndpointServicePermissions', {
        AllowedPrincipals: ['arn:aws:iam::222222222222:root'],
      });
    });

    test('adds TCP:80 ingress from the VPC CIDR on all four upstream ALB SGs', () => {
      const ingressRules = Object.values(
        template.findResources('AWS::EC2::SecurityGroupIngress'),
      ).filter((r: any) =>
        r.Properties?.FromPort === 80 &&
        r.Properties?.Description?.includes('PrivateLink'),
      );
      expect(ingressRules.length).toBe(4);
      for (const rule of ingressRules) {
        expect((rule as any).Properties.IpProtocol).toBe('tcp');
        expect((rule as any).Properties.ToPort).toBe(80);
        expect((rule as any).Properties.CidrIp).toBeDefined();
      }
    });

    test('looks up all four upstream internal ALBs by name', () => {
      const lookups = Object.values(
        template.findResources('Custom::UpstreamAlbLookup'),
      );
      expect(lookups.length).toBe(4);
      const lookedUpNames = lookups.map((l: any) =>
        JSON.stringify(l.Properties?.Create ?? ''),
      );
      expect(lookedUpNames.some((s) => s.includes('LB-petsearch-java'))).toBe(true);
      expect(lookedUpNames.some((s) => s.includes('LB-petlistadoption-py'))).toBe(true);
      expect(lookedUpNames.some((s) => s.includes('LB-petfood-rs'))).toBe(true);
      expect(lookedUpNames.some((s) => s.includes('LB-payforadoption-go'))).toBe(true);
    });

    test('exports the PrivateLink service name', () => {
      template.hasOutput('PetsitePrivatelinkServiceNameOutput', {
        Export: { Name: 'aiops-poc-petsite-privatelink-service-name' },
      });
    });
  });

  // ================================================================
  // PetFood agent cross-account invoke (Waggle chat) tests
  // ================================================================
  describe('PetFood agent resource policies', () => {
    const resourcePolicies = () => {
      const resources = template.toJSON().Resources;
      return Object.values(resources).filter(
        (r: any) => r.Type === 'AWS::BedrockAgentCore::ResourcePolicy'
      ) as any[];
    };

    test('creates resource policies for BOTH the runtime and its endpoint', () => {
      // Hierarchical authorization: cross-account InvokeAgentRuntime needs an
      // explicit allow on the agent runtime AND the endpoint being invoked.
      expect(resourcePolicies()).toHaveLength(2);
    });

    test('policies allow the FE account to invoke the agent runtime', () => {
      // The runtime ARN is a deploy-time SSM token, so the synthesized
      // Policy is an Fn::Join structure rather than a plain string —
      // assert on the serialized form.
      for (const rp of resourcePolicies()) {
        const policyJson = JSON.stringify(rp.Properties.Policy);
        expect(policyJson).toContain('bedrock-agentcore:InvokeAgentRuntime');
        expect(policyJson).toContain('arn:aws:iam::222222222222:root');
        expect(policyJson).toContain('Allow');
      }
    });

    test('runtime ARN is discovered from the upstream SSM contract', () => {
      const templateJson = JSON.stringify(template.toJSON());
      expect(templateJson).toContain('/petstore/petfoodagent-runtime-arn');
    });

    test('endpoint policy targets the DEFAULT runtime endpoint', () => {
      const endpointPolicy = resourcePolicies().find((rp) =>
        JSON.stringify(rp.Properties.ResourceArn).includes('runtime-endpoint/DEFAULT')
      );
      expect(endpointPolicy).toBeDefined();
    });
  });

  // ================================================================
  // FIS Experiment Template tests
  // ================================================================
  describe('FIS Experiment Templates', () => {
    test('payments-crash template exists with correct tag', () => {
      template.hasResourceProperties('AWS::FIS::ExperimentTemplate', {
        Description: Match.stringLikeRegexp('payforadoption-go'),
        Tags: { Name: 'payments-crash' },
      });
    });

    test('search-crash template exists with correct tag', () => {
      template.hasResourceProperties('AWS::FIS::ExperimentTemplate', {
        Description: Match.stringLikeRegexp('petsearch-java'),
        Tags: { Name: 'search-crash' },
      });
    });

    test('payments-crash targets the live payforadoption-go service', () => {
      template.hasResourceProperties('AWS::FIS::ExperimentTemplate', {
        Tags: { Name: 'payments-crash' },
        Targets: Match.objectLike({
          'payment-tasks': Match.objectLike({
            ResourceType: 'aws:ecs:task',
            SelectionMode: 'ALL',
            Parameters: Match.objectLike({
              cluster: 'Services',
              service: 'payforadoption-go',
            }),
          }),
        }),
      });
    });

    test('search-crash targets the live petsearch-java service', () => {
      template.hasResourceProperties('AWS::FIS::ExperimentTemplate', {
        Tags: { Name: 'search-crash' },
        Targets: Match.objectLike({
          'search-tasks': Match.objectLike({
            ResourceType: 'aws:ecs:task',
            SelectionMode: 'ALL',
            Parameters: Match.objectLike({
              cluster: 'Services',
              service: 'petsearch-java',
            }),
          }),
        }),
      });
    });

    test('both templates use aws:ecs:stop-task action', () => {
      const templateJson = template.toJSON();
      const fisTemplates = Object.values(templateJson.Resources).filter(
        (r: any) => r.Type === 'AWS::FIS::ExperimentTemplate'
      );
      expect(fisTemplates.length).toBe(2);
      for (const ft of fisTemplates) {
        const actions = (ft as any).Properties.Actions;
        const actionValues = Object.values(actions) as any[];
        expect(actionValues.some((a: any) => a.ActionId === 'aws:ecs:stop-task')).toBe(true);
      }
    });

    test('both templates have two FIS experiment resources', () => {
      // aws:ecs:stop-task is an instant action (no duration parameter).
      // The chaos scripts handle repeat invocation for sustained outage.
      template.resourceCountIs('AWS::FIS::ExperimentTemplate', 2);
    });

    test('FIS execution role exists with ECS permissions', () => {
      template.hasResourceProperties('AWS::IAM::Role', {
        AssumeRolePolicyDocument: Match.objectLike({
          Statement: Match.arrayWith([
            Match.objectLike({
              Principal: Match.objectLike({
                Service: 'fis.amazonaws.com',
              }),
            }),
          ]),
        }),
      });
    });

    test('FIS role has ecs:StopTask permission', () => {
      template.hasResourceProperties('AWS::IAM::Policy', {
        PolicyDocument: Match.objectLike({
          Statement: Match.arrayWith([
            Match.objectLike({
              Action: Match.arrayWith(['ecs:StopTask']),
              Effect: 'Allow',
            }),
          ]),
        }),
      });
    });
  });

  // ================================================================
  // SNS Topic tests
  // ================================================================
  describe('Incidents SNS Topic', () => {
    test('SNS topic exists with correct name', () => {
      template.hasResourceProperties('AWS::SNS::Topic', {
        TopicName: 'aiops-poc-incidents',
      });
    });

    test('topic policy allows OPS account to subscribe', () => {
      template.hasResourceProperties('AWS::SNS::TopicPolicy', {
        PolicyDocument: Match.objectLike({
          Statement: Match.arrayWith([
            Match.objectLike({
              Sid: 'AllowOpsAccountSubscribe',
              Effect: 'Allow',
              Principal: Match.objectLike({
                AWS: Match.anyValue(),
              }),
              Action: Match.arrayWith(['sns:Subscribe', 'sns:Receive']),
            }),
          ]),
        }),
      });
      // Additionally verify the OPS account ID appears in the synthesized template
      const templateJson = JSON.stringify(template.toJSON());
      expect(templateJson).toContain('333333333333');
    });

    test('topic grants CloudWatch same-account sns:Publish', () => {
      // The cross-account subscribe policy replaced the SNS default and
      // dropped the publish grant, so same-account CloudWatch alarm actions
      // failed. The topic policy must allow the CloudWatch service principal
      // to publish, scoped to the topic's own account via aws:SourceAccount.
      template.hasResourceProperties('AWS::SNS::TopicPolicy', {
        PolicyDocument: Match.objectLike({
          Statement: Match.arrayWith([
            Match.objectLike({
              Sid: 'AllowCloudWatchAlarmPublish',
              Effect: 'Allow',
              Principal: { Service: 'cloudwatch.amazonaws.com' },
              Action: 'sns:Publish',
              Condition: {
                StringEquals: { 'aws:SourceAccount': '111111111111' },
              },
            }),
          ]),
        }),
      });
    });

    test('topic restores the account-owner sns:Publish grant', () => {
      template.hasResourceProperties('AWS::SNS::TopicPolicy', {
        PolicyDocument: Match.objectLike({
          Statement: Match.arrayWith([
            Match.objectLike({
              Sid: 'AllowOwnerPublish',
              Effect: 'Allow',
              Principal: Match.objectLike({ AWS: Match.anyValue() }),
              Action: 'sns:Publish',
            }),
          ]),
        }),
      });
    });

    test('exports the incidents topic ARN', () => {
      template.hasOutput('IncidentsTopicArn', {
        Export: { Name: 'aiops-poc-be-incidents-topic-arn' },
      });
    });
  });

  // ================================================================
  // Business SLO Alarm tests
  // ================================================================
  describe('Business SLO Alarms', () => {
    test('checkout latency alarm exists with correct threshold', () => {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: 'aiops-poc-be-slo-checkout-latency-p99',
        Namespace: 'ApplicationSignals',
        MetricName: 'Latency',
        Threshold: 2000,
        EvaluationPeriods: 3,
        Period: 60,
      });
    });

    // App Signals metrics are keyed on the FULL dimension set
    // [Environment, Service], and the emitted Service name is the
    // "<svc>-api-<lang>" value from the task definition env var — NOT the
    // ECS service name. Alarms missing Environment matched no metric and
    // sat in INSUFFICIENT_DATA (verified live 2026-07-27).
    test('checkout latency alarm uses the payforadoption App Signals dimensions', () => {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: 'aiops-poc-be-slo-checkout-latency-p99',
        Dimensions: Match.arrayWith([
          { Name: 'Environment', Value: 'generic:default' },
          { Name: 'Service', Value: 'payforadoption-api-go' },
        ]),
      });
    });

    // The old service-wide "p95 > 1s for 3x60s" alarm flapped: it mixed three
    // operations (only ~36% real searches), 60s buckets held ~31 samples, and
    // /api/search has a stable ~3s tail. It is now a p99/300s regression
    // detector scoped to GET /api/search with a measured 4s threshold.
    describe('search latency alarm (p99 regression detector)', () => {
      const alarm = () => {
        const found = Object.values(template.toJSON().Resources).filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === 'aiops-poc-be-slo-search-latency-p99',
        ) as any[];
        expect(found).toHaveLength(1);
        return found[0].Properties;
      };

      test('the old flapping p95 alarm no longer exists', () => {
        const p95 = Object.values(template.toJSON().Resources).filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === 'aiops-poc-search-latency-p95',
        );
        expect(p95).toHaveLength(0);
      });

      test('uses p99 over 300s for 2 periods with a 4s threshold', () => {
        const props = alarm();
        expect(props.Namespace).toBe('ApplicationSignals');
        expect(props.MetricName).toBe('Latency');
        expect(props.ExtendedStatistic).toBe('p99');
        expect(props.Period).toBe(300);
        expect(props.EvaluationPeriods).toBe(2);
        expect(props.Threshold).toBe(4000);
        expect(props.ComparisonOperator).toBe('GreaterThanThreshold');
        expect(props.TreatMissingData).toBe('notBreaching');
      });

      test('is scoped to the GET /api/search operation', () => {
        expect(alarm().Dimensions).toEqual(
          expect.arrayContaining([
            { Name: 'Environment', Value: 'ecs:PetsiteECS-cluster' },
            { Name: 'Service', Value: 'petsearch-api-java' },
            { Name: 'Operation', Value: 'GET /api/search' },
          ]),
        );
      });

      // Evidence-only since the three-tier rename: the FE golden signal
      // (aiops-poc-fe-golden-*) is the sole pager, so a BE per-service SLO
      // breach can never open or reframe the incident ahead of the
      // customer-facing symptom. Search latency is one of the five BE SLO
      // alarms whose alarm action was deliberately removed.
      test('does NOT page (no alarm action — evidence only)', () => {
        const actions = alarm().AlarmActions;
        expect(actions === undefined || actions.length === 0).toBe(true);
      });
    });

    test('search error rate alarm exists', () => {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: 'aiops-poc-be-slo-search-error-rate',
        Threshold: 2,
        EvaluationPeriods: 3,
      });
    });

    test('search error rate alarm uses petsearch App Signals dimensions on BOTH metrics', () => {
      const alarms = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          r.Properties?.AlarmName === 'aiops-poc-be-slo-search-error-rate',
      ) as any[];
      expect(alarms).toHaveLength(1);

      const metricStats = alarms[0].Properties.Metrics
        .filter((m: any) => m.MetricStat)
        .map((m: any) => m.MetricStat);
      // faults (Sum) + samples (SampleCount)
      expect(metricStats).toHaveLength(2);
      for (const ms of metricStats) {
        expect(ms.Metric.Namespace).toBe('ApplicationSignals');
        expect(ms.Metric.MetricName).toBe('Fault');
        expect(ms.Metric.Dimensions).toEqual(
          expect.arrayContaining([
            { Name: 'Environment', Value: 'ecs:PetsiteECS-cluster' },
            { Name: 'Service', Value: 'petsearch-api-java' },
          ]),
        );
      }
    });

    // ---- Payments crash (B3) evidence ----
    // A dead service emits no App Signals faults, so the error rate is
    // measured at the caller hop (the payforadoption internal ALB), and
    // paired with a traffic-independent availability alarm. Both are
    // evidence only — the B3 trigger is the FE golden signal.
    describe('payments error rate (measured at the payforadoption ALB)', () => {
      const alarm = () => {
        const found = Object.values(template.toJSON().Resources).filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === 'aiops-poc-be-slo-payments-error-rate',
        ) as any[];
        expect(found).toHaveLength(1);
        return found[0].Properties;
      };

      test('uses a (5xx / requests) * 100 math expression', () => {
        const props = alarm();
        expect(props.Threshold).toBe(2);
        expect(props.EvaluationPeriods).toBe(2);
        expect(props.ComparisonOperator).toBe('GreaterThanThreshold');
        expect(props.TreatMissingData).toBe('notBreaching');
        const expr = props.Metrics.find((m: any) => m.Expression);
        expect(expr.Expression).toBe('(elb5xx / requests) * 100');
      });

      test('measures ALB 5xx and RequestCount at 60s', () => {
        const metricStats = alarm().Metrics
          .filter((m: any) => m.MetricStat)
          .map((m: any) => m.MetricStat);
        expect(metricStats).toHaveLength(2);
        const names = metricStats.map((ms: any) => ms.Metric.MetricName).sort();
        expect(names).toEqual(['HTTPCode_ELB_5XX_Count', 'RequestCount']);
        for (const ms of metricStats) {
          expect(ms.Metric.Namespace).toBe('AWS/ApplicationELB');
          expect(ms.Stat).toBe('Sum');
          expect(ms.Period).toBe(60);
          // LoadBalancer dimension value is derived from the looked-up ALB
          // ARN (deploy-time token), not hardcoded.
          const dims = ms.Metric.Dimensions;
          expect(dims).toHaveLength(1);
          expect(dims[0].Name).toBe('LoadBalancer');
          expect(dims[0].Value).toBeDefined();
        }
      });
    });

    describe('payments availability alarm (HealthyHostCount)', () => {
      const alarm = () => {
        const found = Object.values(template.toJSON().Resources).filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === 'aiops-poc-be-slo-payments-availability',
        ) as any[];
        expect(found).toHaveLength(1);
        return found[0].Properties;
      };

      test('alarms when the minimum healthy host count drops below 1', () => {
        const props = alarm();
        expect(props.Namespace).toBe('AWS/ApplicationELB');
        expect(props.MetricName).toBe('HealthyHostCount');
        expect(props.Statistic).toBe('Minimum');
        expect(props.Period).toBe(60);
        expect(props.Threshold).toBe(1);
        expect(props.EvaluationPeriods).toBe(2);
        expect(props.ComparisonOperator).toBe('LessThanThreshold');
      });

      test('treats missing data as BREACHING (empty target group stops reporting)', () => {
        expect(alarm().TreatMissingData).toBe('breaching');
      });

      test('is dimensioned on both TargetGroup and LoadBalancer', () => {
        const dims = alarm().Dimensions;
        expect(dims.map((d: any) => d.Name).sort())
          .toEqual(['LoadBalancer', 'TargetGroup']);
        for (const d of dims) {
          expect(d.Value).toBeDefined();
        }
      });

      test('derives the target group dimension from a DescribeTargetGroups lookup', () => {
        const lookups = template.findResources('Custom::UpstreamTargetGroupLookup');
        expect(Object.keys(lookups)).toHaveLength(1);
        const create = JSON.stringify(
          Object.values(lookups)[0].Properties?.Create ?? '');
        expect(create).toContain('DescribeTargetGroups');
      });
    });

    test('status update lag alarm uses SQS metric', () => {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: 'aiops-poc-be-slo-statusupdate-lag',
        Namespace: 'AWS/SQS',
        MetricName: 'ApproximateAgeOfOldestMessage',
        Threshold: 300,
        EvaluationPeriods: 3,
      });
    });

    // The QueueName dimension MUST be the live, CloudFormation-generated
    // physical queue name, derived at deploy time from the SSM /petstore/queueurl
    // param (the last URL segment). The old hardcoded upstream LOGICAL name
    // 'petadoptions-statusupdate-queue' matched no published metric, so the
    // alarm never fired and B2 was undetectable (fixed 2026-07-29).
    test('status update lag alarm derives QueueName from the SSM queue URL (not the hardcoded literal)', () => {
      const alarm = Object.values(template.toJSON().Resources).find(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          r.Properties?.AlarmName === 'aiops-poc-be-slo-statusupdate-lag',
      ) as any;
      expect(alarm).toBeDefined();
      const queueDim = alarm.Properties.Dimensions.find(
        (d: any) => d.Name === 'QueueName');
      expect(queueDim).toBeDefined();
      // Must be a deploy-time token (Fn::Select over Fn::Split of the URL),
      // never the stale hardcoded literal.
      expect(queueDim.Value).not.toBe('petadoptions-statusupdate-queue');
      expect(JSON.stringify(queueDim.Value)).toContain('Fn::Select');
      expect(JSON.stringify(queueDim.Value)).toContain('Fn::Split');
    });

    // The five per-service BE SLO alarms are EVIDENCE for an investigation,
    // never its trigger. The FE golden signal (aiops-poc-fe-golden-*) is the
    // sole pager so the incident is framed customer-first — on the
    // 2026-07-28 payments-crash run the BE error-rate alarm fired 13 min
    // before the FE journey alarm and hijacked the framing.
    test('the five evidence-only BE SLO alarms have NO alarm actions', () => {
      const evidenceOnlyAlarmNames = [
        'aiops-poc-be-slo-checkout-latency-p99',
        'aiops-poc-be-slo-payments-error-rate',
        'aiops-poc-be-slo-payments-availability',
        'aiops-poc-be-slo-search-latency-p99',
        'aiops-poc-be-slo-search-error-rate',
      ];
      const alarms = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          evidenceOnlyAlarmNames.includes(r.Properties?.AlarmName),
      ) as any[];
      // All five must EXIST (a rename typo would otherwise pass vacuously).
      expect(alarms).toHaveLength(evidenceOnlyAlarmNames.length);
      for (const alarm of alarms) {
        const actions = alarm.Properties.AlarmActions;
        expect(actions === undefined || actions.length === 0).toBe(true);
      }
    });

    // The ONE exception. B2 (status-update lag) is asynchronous —
    // payforadoption → SQS → petstatusupdater — so checkout stays fast and
    // the FE canary journey passes. No FE golden signal can ever observe it,
    // so this business SLO must page or B2 is undetectable.
    test('status update lag alarm DOES publish to the incidents topic', () => {
      const alarms = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          r.Properties?.AlarmName === 'aiops-poc-be-slo-statusupdate-lag',
      ) as any[];
      expect(alarms).toHaveLength(1);
      const actions = alarms[0].Properties.AlarmActions;
      expect(actions).toBeDefined();
      expect(actions.length).toBeGreaterThan(0);
      const topicId = Object.keys(template.findResources('AWS::SNS::Topic'))[0];
      expect(JSON.stringify(actions)).toContain(topicId);
    });

    // Naming convention: the alarm name encodes the signal's ORIGIN so an
    // investigation title alone tells an operator where it came from
    // (-fe-golden- / -be-slo- / -be-infra-). Every aiops-poc alarm THIS
    // stack creates is a BE alarm, so all of them must carry a BE prefix.
    test('every aiops-poc alarm in this stack carries a -be-slo-/-be-infra- prefix', () => {
      const pocAlarms = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          typeof r.Properties?.AlarmName === 'string' &&
          r.Properties.AlarmName.startsWith('aiops-poc-'),
      ) as any[];
      // Guard against a vacuous pass: this stack owns 6 BE SLO alarms plus
      // 6 BE infra alarms, and creates no ECS services (so no upstream or
      // autoscaling alarms land in this template).
      const allAlarms = template.findResources('AWS::CloudWatch::Alarm');
      expect(Object.keys(allAlarms)).toHaveLength(12);
      expect(pocAlarms).toHaveLength(12);
      for (const alarm of pocAlarms) {
        expect(alarm.Properties.AlarmName).toMatch(/^aiops-poc-be-(slo|infra)-/);
      }
    });

    // The pre-rename names must be fully gone — a half-applied rename would
    // leave duplicate alarms (and stale operator muscle memory) behind.
    test('none of the pre-rename alarm names survive', () => {
      const oldNames = [
        'aiops-poc-checkout-latency-p99',
        'aiops-poc-adoption-error-rate',
        'aiops-poc-adoption-availability',
        'aiops-poc-search-latency-p99',
        'aiops-poc-search-error-rate',
        'aiops-poc-status-update-lag',
      ];
      for (const name of oldNames) {
        const found = Object.values(template.toJSON().Resources).filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === name,
        );
        expect(found).toHaveLength(0);
      }
    });

    // Dual-path routing invariant (was "every PAGING alarm is a
    // business/golden signal, never raw infra"). That invariant no longer
    // holds: aiops-poc-be-infra-payments-tasks is a raw-infra alarm that
    // DELIBERATELY pages. It is the sole exception — it pages the PLATFORM
    // DevOps Agent space (routed by the OPS webhook bridge on the
    // aiops-poc-be-infra-* prefix), never the customer-facing app-team space,
    // so the app-team space still only ever sees business/golden signals.
    //
    // The refined invariant therefore keys off the alarm NAME: the ONLY
    // infra-namespace/infra-metric alarm allowed to carry an AlarmAction is
    // aiops-poc-be-infra-payments-tasks. Every OTHER aiops-poc-be-infra-*
    // alarm must be actionless evidence.
    test('the only paging infra alarm is aiops-poc-be-infra-payments-tasks', () => {
      const infraNamespaces = ['AWS/ECS', 'AWS/EC2', 'ECS/ContainerInsights'];
      const infraMetrics = ['CPUUtilization', 'MemoryUtilization', 'RunningTaskCount'];

      const isInfraAlarm = (props: any): boolean => {
        if (infraNamespaces.includes(props.Namespace)) return true;
        if (infraMetrics.includes(props.MetricName)) return true;
        for (const m of props.Metrics ?? []) {
          if (infraNamespaces.includes(m.MetricStat?.Metric?.Namespace)) return true;
          if (infraMetrics.includes(m.MetricStat?.Metric?.MetricName)) return true;
        }
        return false;
      };

      const infraAlarmsWithAction = Object.values(template.toJSON().Resources)
        .filter(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            isInfraAlarm(r.Properties) &&
            (r.Properties?.AlarmActions?.length ?? 0) > 0,
        )
        .map((r: any) => r.Properties.AlarmName);

      // Exactly one infra alarm pages, and it is the payments tasks alarm.
      expect(infraAlarmsWithAction).toEqual(['aiops-poc-be-infra-payments-tasks']);
    });

    // The complement of the invariant above: every OTHER aiops-poc-be-infra-*
    // alarm must remain pure, actionless evidence.
    test('all other aiops-poc-be-infra-* alarms have no actions', () => {
      const otherInfraAlarms = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          typeof r.Properties?.AlarmName === 'string' &&
          r.Properties.AlarmName.startsWith('aiops-poc-be-infra-') &&
          r.Properties.AlarmName !== 'aiops-poc-be-infra-payments-tasks',
      ) as any[];
      // 5 of the 6 infra alarms (both cpu/memory + search tasks).
      expect(otherInfraAlarms).toHaveLength(5);
      for (const alarm of otherInfraAlarms) {
        const actions = alarm.Properties.AlarmActions;
        expect(actions === undefined || actions.length === 0).toBe(true);
      }
    });

    // The BE SLO alarms' action state is UNCHANGED by the dual-path work:
    // the five evidence-only be-slo-* alarms remain actionless, and
    // be-slo-statusupdate-lag still pages the app-team space. (These are also
    // asserted individually above; re-asserted here as a routing invariant.)
    test('BE SLO alarm action state is unchanged by dual-path routing', () => {
      const evidenceOnly = [
        'aiops-poc-be-slo-checkout-latency-p99',
        'aiops-poc-be-slo-payments-error-rate',
        'aiops-poc-be-slo-payments-availability',
        'aiops-poc-be-slo-search-latency-p99',
        'aiops-poc-be-slo-search-error-rate',
      ];
      const byName = (name: string) =>
        (Object.values(template.toJSON().Resources).find(
          (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
            r.Properties?.AlarmName === name,
        ) as any)?.Properties;

      for (const name of evidenceOnly) {
        const props = byName(name);
        expect(props).toBeDefined();
        const actions = props.AlarmActions;
        expect(actions === undefined || actions.length === 0).toBe(true);
      }

      const lag = byName('aiops-poc-be-slo-statusupdate-lag');
      expect(lag).toBeDefined();
      expect((lag.AlarmActions?.length ?? 0)).toBeGreaterThan(0);
    });
  });

  // ================================================================
  // BE infrastructure alarms (evidence only — must NOT page)
  // ================================================================
  describe('BE infrastructure alarms', () => {
    const alarm = (name: string) => {
      const found = Object.values(template.toJSON().Resources).filter(
        (r: any) => r.Type === 'AWS::CloudWatch::Alarm' &&
          r.Properties?.AlarmName === name,
      ) as any[];
      expect(found).toHaveLength(1);
      return found[0].Properties;
    };

    const infraAlarmNames = [
      'aiops-poc-be-infra-payments-cpu',
      'aiops-poc-be-infra-payments-memory',
      'aiops-poc-be-infra-payments-tasks',
      'aiops-poc-be-infra-search-cpu',
      'aiops-poc-be-infra-search-memory',
      'aiops-poc-be-infra-search-tasks',
    ];

    const services: Array<[string, string]> = [
      ['payments', 'payforadoption-go'],
      ['search', 'petsearch-java'],
    ];

    test.each(services)('%s CPU alarm uses AWS/ECS CPUUtilization > 80%%', (key, svc) => {
      const props = alarm(`aiops-poc-be-infra-${key}-cpu`);
      expect(props.Namespace).toBe('AWS/ECS');
      expect(props.MetricName).toBe('CPUUtilization');
      expect(props.Statistic).toBe('Average');
      expect(props.Period).toBe(60);
      expect(props.Threshold).toBe(80);
      expect(props.EvaluationPeriods).toBe(3);
      expect(props.ComparisonOperator).toBe('GreaterThanThreshold');
      expect(props.TreatMissingData).toBe('notBreaching');
      expect(props.Dimensions).toEqual(
        expect.arrayContaining([
          { Name: 'ClusterName', Value: 'Services' },
          { Name: 'ServiceName', Value: svc },
        ]),
      );
    });

    test.each(services)('%s memory alarm uses AWS/ECS MemoryUtilization > 80%%', (key, svc) => {
      const props = alarm(`aiops-poc-be-infra-${key}-memory`);
      expect(props.Namespace).toBe('AWS/ECS');
      expect(props.MetricName).toBe('MemoryUtilization');
      expect(props.Statistic).toBe('Average');
      expect(props.Period).toBe(60);
      expect(props.Threshold).toBe(80);
      expect(props.EvaluationPeriods).toBe(3);
      expect(props.ComparisonOperator).toBe('GreaterThanThreshold');
      expect(props.TreatMissingData).toBe('notBreaching');
      expect(props.Dimensions).toEqual(
        expect.arrayContaining([
          { Name: 'ClusterName', Value: 'Services' },
          { Name: 'ServiceName', Value: svc },
        ]),
      );
    });

    test.each(services)('%s task-count alarm breaches on silence', (key, svc) => {
      const props = alarm(`aiops-poc-be-infra-${key}-tasks`);
      expect(props.Namespace).toBe('ECS/ContainerInsights');
      expect(props.MetricName).toBe('RunningTaskCount');
      expect(props.Statistic).toBe('Minimum');
      expect(props.Period).toBe(60);
      expect(props.Threshold).toBe(1);
      expect(props.EvaluationPeriods).toBe(2);
      expect(props.ComparisonOperator).toBe('LessThanThreshold');
      // A fully-stopped service stops publishing; that silence IS the event.
      expect(props.TreatMissingData).toBe('breaching');
      expect(props.Dimensions).toEqual(
        expect.arrayContaining([
          { Name: 'ClusterName', Value: 'Services' },
          { Name: 'ServiceName', Value: svc },
        ]),
      );
    });

    test('all six infra alarms exist', () => {
      for (const name of infraAlarmNames) {
        expect(alarm(name)).toBeDefined();
      }
    });

    // Deliberate exception (dual-path routing): payments-tasks pages the
    // PLATFORM space, so it is excluded from the "must not page" set below.
    const evidenceOnlyInfraAlarmNames = infraAlarmNames.filter(
      (n) => n !== 'aiops-poc-be-infra-payments-tasks',
    );

    test('the five evidence-only infra alarms have NO actions (they must not page)', () => {
      for (const name of evidenceOnlyInfraAlarmNames) {
        const props = alarm(name);
        expect(props.AlarmActions).toBeUndefined();
        expect(props.OKActions).toBeUndefined();
        expect(props.InsufficientDataActions).toBeUndefined();
      }
    });

    test('each evidence-only infra alarm description marks it as non-paging evidence', () => {
      for (const name of evidenceOnlyInfraAlarmNames) {
        expect(alarm(name).AlarmDescription)
          .toContain('infra evidence (does not page)');
      }
    });

    // ---- The one deliberate paging infra alarm (dual-path routing) ----
    // aiops-poc-be-infra-payments-tasks is the single infra alarm that pages.
    // It publishes to the BE incidents topic; the OPS webhook bridge routes
    // aiops-poc-be-infra-* alarms to the PLATFORM DevOps Agent space so it can
    // run its own live RCA. search-tasks stays actionless evidence.
    test('payments-tasks HAS exactly one AlarmAction referencing the incidents topic', () => {
      const props = alarm('aiops-poc-be-infra-payments-tasks');
      const actions = props.AlarmActions;
      expect(actions).toBeDefined();
      expect(actions).toHaveLength(1);
      const topicId = Object.keys(template.findResources('AWS::SNS::Topic'))[0];
      expect(JSON.stringify(actions)).toContain(topicId);
    });

    test('search-tasks has NO action (only payments-tasks pages)', () => {
      const props = alarm('aiops-poc-be-infra-search-tasks');
      expect(props.AlarmActions).toBeUndefined();
    });
  });

  // ================================================================
  // Petsite scale-to-zero tests
  // ================================================================
  describe('Petsite Scale to Zero', () => {
    test('stack contains NO ECS service resources (petsite scale-to-zero intentionally omitted)', () => {
      // The upstream one-observability-demo runs petsite on EKS
      // (PetsiteEKS-cluster), not as an ECS service, so there is no ECS
      // "petsite" service to scale to zero. A CfnService would also create
      // a new service rather than scale an existing one. The construct was
      // intentionally removed from the stack (see backend-overlay-stack.ts).
      template.resourceCountIs('AWS::ECS::Service', 0);
    });
  });
});


describe('BackendOverlayStack - aiops-backend-domain-read role', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new BackendOverlayStack(app, 'TestReadRoleStack', {
      env: { account: '111111111111', region: 'us-east-1' },
      opsAccountId: '333333333333',
      frontendAccountId: '222222222222',
      clusterNameOverride: 'Services',
    });
    template = Template.fromStack(stack);
  });

  test('role exists with the correct name', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-backend-domain-read',
    });
  });

  // The stack trusts the OPS account principal scoped down to the specific
  // agent/MCP task role ARNs via an aws:PrincipalArn condition (using
  // ArnPrincipal directly would require those roles to exist at deploy
  // time, creating a cross-account ordering dependency). The assertions
  // below match that synthesized structure.
  test('trust policy allows OPS agent task role via aws:PrincipalArn condition', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-backend-domain-read',
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 'sts:AssumeRole',
            Condition: Match.objectLike({
              ArnEquals: Match.objectLike({
                'aws:PrincipalArn': Match.arrayWith([
                  'arn:aws:iam::333333333333:role/aiops-poc-agent-task-role',
                ]),
              }),
            }),
          }),
        ]),
      }),
    });
  });

  test('trust policy allows OPS MCP task role via aws:PrincipalArn condition', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'aiops-backend-domain-read',
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 'sts:AssumeRole',
            Condition: Match.objectLike({
              ArnEquals: Match.objectLike({
                'aws:PrincipalArn': Match.arrayWith([
                  'arn:aws:iam::333333333333:role/aiops-poc-mcp-task-role',
                ]),
              }),
            }),
          }),
        ]),
      }),
    });
  });

  test('trust policy does NOT allow the entire OPS account root', () => {
    const templateJson = JSON.stringify(template.toJSON());
    expect(templateJson).not.toContain('"arn:aws:iam::333333333333:root"');
  });

  test('inline policy contains only read-only actions (no write actions)', () => {
    const resources = template.toJSON().Resources;
    const policyResources = Object.values(resources).filter(
      (r: any) => r.Type === 'AWS::IAM::Policy'
    ) as any[];

    expect(policyResources.length).toBeGreaterThan(0);

    // Gather all actions from policies that belong to the domain-read role
    const allActions: string[] = [];
    for (const policy of policyResources) {
      const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        if (Array.isArray(stmt.Action)) {
          allActions.push(...stmt.Action);
        } else if (stmt.Action) {
          allActions.push(stmt.Action);
        }
      }
    }

    // Verify no write actions among our read-only policy actions
    // Filter to only the actions from the BackendDomainReadRole policy
    const domainReadActions = allActions.filter(a =>
      a.startsWith('cloudwatch:') || a.startsWith('ecs:Describe') ||
      a.startsWith('ecs:List') || a.startsWith('dynamodb:') ||
      a.startsWith('sqs:') || a.startsWith('rds:') ||
      a.startsWith('lambda:') || a.startsWith('synthetics:') ||
      a.startsWith('ssm:Get') || a.startsWith('logs:')
    );

    const writePatterns = [
      /^.*:Put/i,
      /^.*:Create/i,
      /^.*:Delete/i,
      /^.*:Update/i,
      /^.*:Start/i,
      /^.*:Stop/i,
      /^.*:Terminate/i,
      /^.*:Send/i,
      /^.*:Publish/i,
      /^.*:Remove/i,
      /^.*:Invoke/i,
    ];

    for (const action of domainReadActions) {
      for (const pattern of writePatterns) {
        expect(action).not.toMatch(pattern);
      }
    }
  });

  test('inline policy includes expected read-only services', () => {
    const resources = template.toJSON().Resources;
    const policyResources = Object.values(resources).filter(
      (r: any) => r.Type === 'AWS::IAM::Policy'
    ) as any[];

    const allActions: string[] = [];
    for (const policy of policyResources) {
      const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        if (Array.isArray(stmt.Action)) {
          allActions.push(...stmt.Action);
        } else if (stmt.Action) {
          allActions.push(stmt.Action);
        }
      }
    }

    expect(allActions).toEqual(expect.arrayContaining([
      'cloudwatch:GetMetricStatistics',
      'ecs:DescribeServices',
      'dynamodb:Query',
      'sqs:GetQueueAttributes',
      'rds:DescribeDBInstances',
      'lambda:GetFunctionConfiguration',
      'synthetics:GetCanaryRuns',
      'ssm:GetParameter',
      'logs:FilterLogEvents',
    ]));
  });

  test('SSM read is scoped to /petstore/* path only', () => {
    const resources = template.toJSON().Resources;
    const policyResources = Object.values(resources).filter(
      (r: any) => r.Type === 'AWS::IAM::Policy'
    ) as any[];

    let ssmStatement: any = null;
    for (const policy of policyResources) {
      const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
      for (const stmt of statements) {
        const actions = Array.isArray(stmt.Action) ? stmt.Action : [stmt.Action];
        if (actions.includes('ssm:GetParameter')) {
          ssmStatement = stmt;
          break;
        }
      }
    }

    expect(ssmStatement).not.toBeNull();
    const resource = Array.isArray(ssmStatement.Resource)
      ? ssmStatement.Resource[0]
      : ssmStatement.Resource;
    expect(resource).toContain('parameter/petstore/*');
    expect(resource).not.toBe('*');
  });

  test('role ARN is exported as stack output', () => {
    template.hasOutput('BackendDomainReadRoleArn', {
      Export: { Name: 'aiops-poc-backend-domain-read-role-arn' },
    });
  });
});
