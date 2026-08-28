import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { FrontendStack } from '../lib/frontend-stack';

describe('FrontendStack', () => {
  let app: cdk.App;
  let stack: FrontendStack;
  let template: Template;

  beforeAll(() => {
    app = new cdk.App();

    stack = new FrontendStack(app, 'TestFrontendStack', {
      env: { account: '222222222222', region: 'us-east-1' },
      opsAccountId: '333333333333',
      backendAccountId: '111111111111',
      upstreamOrg: 'aws-samples',
      upstreamRepo: 'one-observability-demo',
      upstreamRef: 'main',
      maxCapacityOverride: 4,
      cfPrefixListIdOverride: 'pl-12345678',
      privatelinkServiceNameOverride:
        'com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0',
    });

    template = Template.fromStack(stack);
  });

  test('stack synthesizes without errors', () => {
    expect(template).toBeDefined();
  });

  test('creates a VPC', () => {
    template.resourceCountIs('AWS::EC2::VPC', 1);
  });

  test('creates an ECS cluster', () => {
    template.hasResourceProperties('AWS::ECS::Cluster', {
      ClusterName: 'aiops-poc-petsite',
    });
  });

  test('creates an ECS Fargate service', () => {
    template.hasResourceProperties('AWS::ECS::Service', {
      ServiceName: 'petsite',
      LaunchType: 'FARGATE',
    });
  });

  test('task definition sets petsite SSM parameter-name env vars (upstream contract)', () => {
    // petsite reads SSM parameter NAMES from these env vars and prepends
    // PARAMETER_STORE_PREFIX; mapping must match upstream's canonical
    // petsite deployment exactly.
    const expectedEnv: Record<string, string> = {
      ASPNETCORE_URLS: 'http://+:80',
      PARAMETER_STORE_PREFIX: '/petstore',
      PET_HISTORY_URL_PARAM_NAME: 'pethistoryurl',
      PET_LIST_ADOPTIONS_URL_PARAM_NAME: 'petlistadoptionsurl',
      CLEANUP_ADOPTIONS_URL_PARAM_NAME: 'cleanupadoptionsurl',
      PAYMENT_API_URL_PARAM_NAME: 'paymentapiurl',
      FOOD_API_URL_PARAM_NAME: 'petfoodapiurl',
      CART_API_URL_PARAM_NAME: 'petfoodcarturl',
      SEARCH_API_URL_PARAM_NAME: 'searchapiurl',
      RUM_SCRIPT_PARAMETER_NAME: 'rumscriptparameter',
      PETFOOD_AGENT_RUNTIME_ARN_NAME: 'petfoodagent-runtime-arn',
    };

    template.hasResourceProperties('AWS::ECS::TaskDefinition', {
      ContainerDefinitions: Match.arrayWith([
        Match.objectLike({
          Environment: Match.arrayWith(
            Object.entries(expectedEnv).map(([name, value]) =>
              Match.objectLike({ Name: name, Value: value }),
            ),
          ),
        }),
      ]),
    });
  });

  test('task definition sets AWS region env vars for the SSM client', () => {
    template.hasResourceProperties('AWS::ECS::TaskDefinition', {
      ContainerDefinitions: Match.arrayWith([
        Match.objectLike({
          Environment: Match.arrayWith([
            Match.objectLike({ Name: 'AWS_REGION' }),
            Match.objectLike({ Name: 'AWS_DEFAULT_REGION' }),
          ]),
        }),
      ]),
    });
  });

  test('creates a public ALB', () => {
    template.hasResourceProperties(
      'AWS::ElasticLoadBalancingV2::LoadBalancer',
      {
        Scheme: 'internet-facing',
        Type: 'application',
      },
    );
  });

  test('configures autoscaling target', () => {
    template.hasResourceProperties('AWS::ApplicationAutoScaling::ScalableTarget', {
      MinCapacity: 2,
      MaxCapacity: 4,
    });
  });

  test('configures CPU-based autoscaling policy', () => {
    template.hasResourceProperties('AWS::ApplicationAutoScaling::ScalingPolicy', {
      PolicyType: 'TargetTrackingScaling',
      TargetTrackingScalingPolicyConfiguration: Match.objectLike({
        PredefinedMetricSpecification: {
          PredefinedMetricType: 'ECSServiceAverageCPUUtilization',
        },
        TargetValue: 70,
      }),
    });
  });

  test('configures request-based autoscaling policy', () => {
    template.hasResourceProperties('AWS::ApplicationAutoScaling::ScalingPolicy', {
      PolicyType: 'TargetTrackingScaling',
      TargetTrackingScalingPolicyConfiguration: Match.objectLike({
        PredefinedMetricSpecification: {
          PredefinedMetricType: 'ALBRequestCountPerTarget',
        },
        TargetValue: 1000,
      }),
    });
  });

  test('publishes petsite URL to SSM', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/workload/petsite-url',
      Type: 'String',
    });
  });

  test('creates max-capacity SSM parameter', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/workload/petsite-max-capacity',
      Type: 'String',
      Value: '4',
    });
  });

  test('publishes the FE ECS cluster name to SSM for the chaos tooling', () => {
    // ui-no-scale in chaos/scripts/{inject,restore}.sh resolves the FE ECS
    // names from these params instead of hardcoding them.
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/workload/fe-ecs-cluster',
      Type: 'String',
      // Ref on an ECS cluster resolves to the cluster name at deploy time.
      Value: { Ref: Match.stringLikeRegexp('^PetsiteCluster') },
    });
  });

  test('publishes the FE ECS service name to SSM for the chaos tooling', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/aiops-poc/workload/fe-ecs-service',
      Type: 'String',
      // Fn::GetAtt <service>.Name resolves to the service name at deploy time.
      Value: { 'Fn::GetAtt': [Match.stringLikeRegexp('^PetsiteService'), 'Name'] },
    });
  });

  test('exports petsite ALB URL', () => {
    template.hasOutput('PetsiteAlbUrl', {
      Export: { Name: 'aiops-poc-petsite-url' },
    });
  });

  test('exports petsite service ARN', () => {
    template.hasOutput('PetsiteServiceArn', {
      Export: { Name: 'aiops-poc-petsite-service-arn' },
    });
  });

  test('exports OPS account ID', () => {
    template.hasOutput('OpsAccountId', {
      Value: '333333333333',
      Export: { Name: 'aiops-poc-fe-ops-account-id' },
    });
  });

  test('stack is independently deployable with FE account', () => {
    expect(stack.account).toBe('222222222222');
    expect(stack.region).toBe('us-east-1');
  });

  test('petsite URL property is set (https via CloudFront)', () => {
    expect(stack.petsiteUrl).toBeDefined();
    expect(stack.petsiteUrl).toContain('https://');
  });

  // ================================================================
  // CloudFront in front of the ALB + SG lockdown
  // ================================================================

  test('creates a CloudFront distribution fronting the ALB', () => {
    template.resourceCountIs('AWS::CloudFront::Distribution', 1);
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        DefaultCacheBehavior: Match.objectLike({
          ViewerProtocolPolicy: 'redirect-to-https',
          // CachingDisabled managed cache policy
          CachePolicyId: '4135ea2d-6df8-44a3-9df3-4b5a84be39ad',
          // AllViewer managed origin request policy
          OriginRequestPolicyId: '216adef6-5c7f-47e4-b989-5492eafa07d3',
        }),
        Origins: Match.arrayWith([
          Match.objectLike({
            CustomOriginConfig: Match.objectLike({
              OriginProtocolPolicy: 'http-only',
              HTTPPort: 80,
            }),
          }),
        ]),
      }),
    });
  });

  test('ALB security group does NOT allow 0.0.0.0/0 on port 80', () => {
    const sgs = template.findResources('AWS::EC2::SecurityGroup');
    for (const sg of Object.values(sgs)) {
      const ingress = sg.Properties?.SecurityGroupIngress ?? [];
      for (const rule of ingress) {
        expect(rule.CidrIp).not.toBe('0.0.0.0/0');
      }
    }
  });

  test('ALB security group allows ingress from CloudFront origin-facing prefix list', () => {
    template.hasResourceProperties('AWS::EC2::SecurityGroupIngress', {
      IpProtocol: 'tcp',
      FromPort: 80,
      ToPort: 80,
      SourcePrefixListId: 'pl-12345678',
    });
  });

  test('exports CloudFront URL and ALB DNS outputs', () => {
    template.hasOutput('PetsiteCloudFrontUrl', {
      Export: { Name: 'aiops-poc-petsite-cloudfront-url' },
    });
    template.hasOutput('PetsiteAlbDns', {
      Export: { Name: 'aiops-poc-petsite-alb-dns' },
    });
  });

  // ================================================================
  // SSM URL parameters for petsite native service discovery
  // ================================================================

  test('creates SSM parameter /petstore/searchapiurl', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/searchapiurl',
      Type: 'String',
    });
  });

  test('creates SSM parameter /petstore/paymentapiurl', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/paymentapiurl',
      Type: 'String',
    });
  });

  test('does NOT create the legacy /petstore/payforadoptionurl placeholder', () => {
    // petsite reads paymentapiurl (PAYMENT_API_URL_PARAM_NAME) for the
    // adopt/checkout flow — payforadoptionurl is a dead parameter name.
    const params = template.findResources('AWS::SSM::Parameter');
    const legacy = Object.values(params).filter(
      (p: any) => p.Properties?.Name === '/petstore/payforadoptionurl',
    );
    expect(legacy.length).toBe(0);
  });

  test('creates SSM parameter /petstore/petlistadoptionsurl', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/petlistadoptionsurl',
      Type: 'String',
    });
  });

  test('creates SSM parameter /petstore/updateadoptionstatusurl', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/updateadoptionstatusurl',
      Type: 'String',
    });
  });

  // ================================================================
  // PrivateLink interface endpoint to BE (petsearch + petlistadoption)
  // ================================================================

  test('creates an interface VPC endpoint to the BE PrivateLink service', () => {
    template.hasResourceProperties('AWS::EC2::VPCEndpoint', {
      VpcEndpointType: 'Interface',
      ServiceName: 'com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0',
      PrivateDnsEnabled: false,
    });
  });

  test('endpoint SG allows TCP 80, 8080, 8081 and 8082 from the petsite service SG', () => {
    const ingressRules = Object.values(
      template.findResources('AWS::EC2::SecurityGroupIngress'),
    ).filter((r: any) => r.Properties?.Description?.includes('PrivateLink'));

    const ports = ingressRules.map((r: any) => r.Properties.FromPort).sort();
    expect(ports).toEqual([80, 8080, 8081, 8082]);
    for (const rule of ingressRules) {
      expect((rule as any).Properties.IpProtocol).toBe('tcp');
      // Source is the petsite tasks security group, not a CIDR
      expect((rule as any).Properties.SourceSecurityGroupId).toBeDefined();
      expect((rule as any).Properties.CidrIp).toBeUndefined();
    }
  });

  test('searchapiurl points at the endpoint DNS with trailing "?" path', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/searchapiurl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', '/api/search?'])],
      },
    });
  });

  test('petlistadoptionsurl points at the endpoint DNS on :8080 with trailing "/"', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/petlistadoptionsurl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', ':8080/api/adoptionlist/'])],
      },
    });
  });

  test('petfoodapiurl points at the endpoint DNS on :8081 with "/api/foods" (no trailing slash)', () => {
    // Mirrors the BE value http://<internal-alb>/api/foods with only
    // host:port swapped — petsite string-concatenates onto this value.
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/petfoodapiurl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', ':8081/api/foods'])],
      },
    });
  });

  test('petfoodcarturl points at the endpoint DNS on :8081 with "/api/cart" (no trailing slash)', () => {
    // Mirrors the BE value http://<internal-alb>/api/cart with only
    // host:port swapped.
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/petfoodcarturl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', ':8081/api/cart'])],
      },
    });
  });

  test('cleanupadoptionsurl points at the endpoint DNS on :8082 with "/api/cleanupadoptions" (no trailing slash)', () => {
    // Mirrors the BE value http://<internal-alb>/api/cleanupadoptions with
    // only host:port swapped — petsite appends '/<userId>' and issues DELETE.
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/cleanupadoptionsurl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', ':8082/api/cleanupadoptions'])],
      },
    });
  });

  test('paymentapiurl points at the endpoint DNS on :8082 with "/api/completeadoption" (no trailing slash)', () => {
    // Mirrors the BE value http://<internal-alb>/api/completeadoption with
    // only host:port swapped — petsite's adopt/checkout flow POSTs here.
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/paymentapiurl',
      Value: {
        'Fn::Join': ['', Match.arrayWith(['http://', ':8082/api/completeadoption'])],
      },
    });
  });

  test('the six PrivateLink URL params reference the endpoint DNS entries', () => {
    const params = template.findResources('AWS::SSM::Parameter');
    const urlParams = Object.values(params).filter((p: any) =>
      [
        '/petstore/searchapiurl',
        '/petstore/petlistadoptionsurl',
        '/petstore/petfoodapiurl',
        '/petstore/petfoodcarturl',
        '/petstore/cleanupadoptionsurl',
        '/petstore/paymentapiurl',
      ].includes(p.Properties?.Name),
    );
    expect(urlParams.length).toBe(6);
    for (const p of urlParams) {
      expect(JSON.stringify((p as any).Properties.Value)).toContain('DnsEntries');
    }
  });

  test('updateadoptionstatus stays as a sync-owned placeholder', () => {
    template.hasResourceProperties('AWS::SSM::Parameter', {
      Name: '/petstore/updateadoptionstatusurl',
      Value: 'http://placeholder-updateadoptionstatus.internal',
    });
  });

  // ================================================================
  // Synthetics journey canary
  // ================================================================

  test('creates journey canary on a 1-minute schedule (detection speed)', () => {
    // 1 minute is the detection floor for the journey golden signals: at the
    // previous 5-minute rate the FE golden signal fired 17m37s AFTER the BE
    // infra task-count alarm (measured 2026-07-28).
    template.hasResourceProperties('AWS::Synthetics::Canary', {
      Name: 'aiops-poc-journey',
      Schedule: Match.objectLike({
        Expression: 'rate(1 minute)',
      }),
      RuntimeVersion: 'syn-nodejs-puppeteer-9.1',
    });
  });

  // ================================================================
  // Journey SLO alarms
  // ================================================================

  test('journey canary script exercises the checkout path (payforadoption)', () => {
    // Without a checkout step the FE is blind to a payments outage: petsite
    // only calls payforadoption on /housekeeping (cleanupadoptionsurl) and
    // /Payment/MakePayment (paymentapiurl).
    template.hasResourceProperties('AWS::Synthetics::Canary', {
      Code: Match.objectLike({
        Script: Match.stringLikeRegexp('/housekeeping\\?userId='),
      }),
    });
    template.hasResourceProperties('AWS::Synthetics::Canary', {
      Code: Match.objectLike({
        Script: Match.stringLikeRegexp('Payment/MakePayment'),
      }),
    });
    template.hasResourceProperties('AWS::Synthetics::Canary', {
      Code: Match.objectLike({
        Script: Match.stringLikeRegexp('Step 4b - Checkout'),
      }),
    });
  });

  test('checkout step only fails on server errors (no 4xx false alarms)', () => {
    const canaries = template.findResources('AWS::Synthetics::Canary');
    const script = Object.values(canaries)[0].Properties.Code.Script as string;
    expect(script).toContain('>= 500');
    // The three original steps stay status >= 400 assertions and must remain.
    expect(script).toContain('Step 1 - Browse homepage');
    expect(script).toContain('Step 2 - Search for pets');
    expect(script).toContain('Step 3 - View adoption list');
  });

  test('search step (2) adds a content check for real pet results (search-crash gap)', () => {
    // petsite masks a dead/degraded petsearch as a FAST HTTP 200 error page, so
    // a status-only search assertion is blind to a search outage (verified
    // 2026-07-28: 19/19 canary runs PASSED through a full petsearch crash).
    // Step 2 must therefore also assert the search RESULTS rendered, keyed on
    // result-card markup (petid / adopt form / thumbnail), NOT the search
    // dropdown — mirroring the step-4a content-check pattern.
    const canaries = template.findResources('AWS::Synthetics::Canary');
    const script = Object.values(canaries)[0].Properties.Code.Script as string;
    // The search step reads the rendered page and inspects its content.
    expect(script).toContain('const searchBody = await page.content();');
    // The assertion keys on real pet-result markup (any of these markers).
    expect(script).toMatch(/name="petid"|id="pet_petid"|takemehome|pet-thumbnail/);
    // It throws a descriptive error when no results are present.
    expect(script).toContain(
      'Search returned no results — petsearch dependency unavailable/degraded',
    );
  });

  // ================================================================
  // FE golden-signal alarm: petsite ALB 5xx error rate
  // ================================================================

  test('creates FE checkout error-rate alarm (golden signal, 5xx rate > 2%)', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'aiops-poc-fe-golden-checkout-error-rate',
      Threshold: 2,
      EvaluationPeriods: 2,
      ComparisonOperator: 'GreaterThanThreshold',
      TreatMissingData: 'notBreaching',
      Metrics: Match.arrayWith([
        Match.objectLike({
          Expression: '(target5xx + elb5xx) / requests * 100',
        }),
      ]),
    });
  });

  test('FE error-rate alarm uses the petsite ALB 5xx + request metrics', () => {
    const expected = [
      'HTTPCode_Target_5XX_Count',
      'HTTPCode_ELB_5XX_Count',
      'RequestCount',
    ];
    for (const metricName of expected) {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: 'aiops-poc-fe-golden-checkout-error-rate',
        Metrics: Match.arrayWith([
          Match.objectLike({
            MetricStat: Match.objectLike({
              Stat: 'Sum',
              Period: 60,
              Metric: Match.objectLike({
                Namespace: 'AWS/ApplicationELB',
                MetricName: metricName,
                Dimensions: [
                  { Name: 'LoadBalancer', Value: Match.anyValue() },
                ],
              }),
            }),
          }),
        ]),
      });
    }
  });

  test('FE error-rate alarm pages via the FE incidents topic', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'aiops-poc-fe-golden-checkout-error-rate',
      AlarmDescription: Match.stringLikeRegexp('GOLDEN SIGNAL'),
    });

    // The alarm action must be the FE incidents topic (it pages a human);
    // BE infrastructure alarms deliberately have no actions.
    const topicId = Object.keys(template.findResources('AWS::SNS::Topic'))[0];
    const alarms = template.findResources('AWS::CloudWatch::Alarm', {
      Properties: { AlarmName: 'aiops-poc-fe-golden-checkout-error-rate' },
    });
    const alarm = Object.values(alarms)[0];
    expect(alarm.Properties.AlarmActions).toEqual([{ Ref: topicId }]);
  });

  test('creates journey success alarm (SuccessPercent < 90%, 1-of-2 60s)', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'aiops-poc-fe-golden-journey-success',
      Namespace: 'CloudWatchSynthetics',
      MetricName: 'SuccessPercent',
      Threshold: 90,
      Period: 60,
      EvaluationPeriods: 2,
      DatapointsToAlarm: 1,
      ComparisonOperator: 'LessThanThreshold',
      TreatMissingData: 'notBreaching',
    });
  });

  test('creates journey duration alarm (Duration > 10000ms, 1-of-2 60s)', () => {
    template.hasResourceProperties('AWS::CloudWatch::Alarm', {
      AlarmName: 'aiops-poc-fe-golden-journey-duration',
      Namespace: 'CloudWatchSynthetics',
      MetricName: 'Duration',
      Threshold: 10000,
      Period: 60,
      EvaluationPeriods: 2,
      DatapointsToAlarm: 1,
      ComparisonOperator: 'GreaterThanThreshold',
      TreatMissingData: 'notBreaching',
    });
  });

  test('journey alarms keep the canary dimension (canary itself not renamed)', () => {
    for (const alarmName of [
      'aiops-poc-fe-golden-journey-success',
      'aiops-poc-fe-golden-journey-duration',
    ]) {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: alarmName,
        Dimensions: [{ Name: 'CanaryName', Value: 'aiops-poc-journey' }],
      });
    }
  });

  test('journey alarms page via the FE incidents topic and stay golden signals', () => {
    const topicId = Object.keys(template.findResources('AWS::SNS::Topic'))[0];
    for (const alarmName of [
      'aiops-poc-fe-golden-journey-success',
      'aiops-poc-fe-golden-journey-duration',
    ]) {
      template.hasResourceProperties('AWS::CloudWatch::Alarm', {
        AlarmName: alarmName,
        AlarmDescription: Match.stringLikeRegexp('GOLDEN SIGNAL'),
        AlarmActions: [{ Ref: topicId }],
      });
    }
  });

  test('no alarm keeps a legacy (pre-fe-golden) name', () => {
    const legacyNames = [
      'aiops-poc-journey-success',
      'aiops-poc-journey-duration',
      'aiops-poc-fe-checkout-error-rate',
    ];
    const names = Object.values(template.findResources('AWS::CloudWatch::Alarm'))
      .map((a: any) => a.Properties?.AlarmName);
    for (const legacy of legacyNames) {
      expect(names).not.toContain(legacy);
    }
  });

  test('all FE alarms follow the aiops-poc-fe-golden-* convention', () => {
    // The name encodes tier + signal class so an investigation title is
    // self-describing without opening the alarm.
    const names = Object.values(template.findResources('AWS::CloudWatch::Alarm'))
      .map((a: any) => a.Properties?.AlarmName)
      .filter((n: any) => typeof n === 'string');
    expect(names.length).toBe(3);
    for (const name of names) {
      expect(name).toMatch(/^aiops-poc-fe-golden-/);
    }
  });

  // ================================================================
  // FE incidents SNS topic + OPS account topic policy
  // ================================================================

  test('creates FE incidents SNS topic', () => {
    template.hasResourceProperties('AWS::SNS::Topic', {
      TopicName: 'aiops-poc-fe-incidents',
      DisplayName: 'AIOps PoC Frontend Incidents',
    });
  });

  test('FE incidents topic has OPS account subscribe policy', () => {
    template.hasResourceProperties('AWS::SNS::TopicPolicy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'AllowOpsAccountSubscribe',
            Effect: 'Allow',
            Principal: { AWS: Match.anyValue() },
            Action: Match.arrayWith(['sns:Subscribe', 'sns:Receive']),
          }),
        ]),
      }),
    });
  });

  test('FE incidents topic grants CloudWatch same-account sns:Publish', () => {
    // The cross-account subscribe policy replaced the SNS default and dropped
    // the publish grant, so same-account CloudWatch alarm actions failed.
    // The topic policy must allow the CloudWatch service principal to publish,
    // scoped to the topic's own account via aws:SourceAccount.
    template.hasResourceProperties('AWS::SNS::TopicPolicy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'AllowCloudWatchAlarmPublish',
            Effect: 'Allow',
            Principal: { Service: 'cloudwatch.amazonaws.com' },
            Action: 'sns:Publish',
            Condition: {
              StringEquals: { 'aws:SourceAccount': '222222222222' },
            },
          }),
        ]),
      }),
    });
  });

  test('FE incidents topic restores the account-owner sns:Publish grant', () => {
    template.hasResourceProperties('AWS::SNS::TopicPolicy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'AllowOwnerPublish',
            Effect: 'Allow',
            Principal: { AWS: Match.anyValue() },
            Action: 'sns:Publish',
          }),
        ]),
      }),
    });
  });

  test('exports FE incidents topic ARN', () => {
    template.hasOutput('FeIncidentsTopicArn', {
      Export: { Name: 'aiops-poc-fe-incidents-topic-arn' },
    });
  });

  test('exports journey canary name', () => {
    template.hasOutput('JourneyCanaryName', {
      Export: { Name: 'aiops-poc-journey-canary-name' },
    });
  });

  // ================================================================
  // Waggle chat: cross-account PetFood agent invoke (Bedrock AgentCore)
  // ================================================================

  test('task role may invoke the BE PetFood agent runtime (Waggle chat)', () => {
    // Mirrors the upstream petsite policy shape (runtime/PetFoodAgent*),
    // pointed at the BE account where the AgentCore runtime lives. The
    // wildcard also covers the runtime's endpoint ARNs
    // (<runtime-arn>/runtime-endpoint/DEFAULT), which hierarchical
    // authorization evaluates alongside the runtime.
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Sid: 'PetfoodAgentInvoke',
            Effect: 'Allow',
            Action: 'bedrock-agentcore:InvokeAgentRuntime',
            Resource:
              'arn:aws:bedrock-agentcore:us-east-1:111111111111:runtime/PetFoodAgent*',
          }),
        ]),
      }),
    });
  });
});
