import * as cdk from 'aws-cdk-lib';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cw_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecs_patterns from 'aws-cdk-lib/aws-ecs-patterns';
import { Platform } from 'aws-cdk-lib/aws-ecr-assets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as synthetics from 'aws-cdk-lib/aws-synthetics';
import * as path from 'path';
import { Construct } from 'constructs';

/**
 * Configuration for the FrontendStack.
 */
export interface FrontendStackProps extends cdk.StackProps {
  /** The OPS account ID (for cross-account SNS topic policy). */
  readonly opsAccountId: string;
  /**
   * The BE account ID (petsite invokes the PetFood agent — a Bedrock
   * AgentCore runtime deployed by the upstream in the BE account — for
   * the Waggle chat).
   */
  readonly backendAccountId: string;
  /** Upstream GitHub org (default: aws-samples). */
  readonly upstreamOrg?: string;
  /** Upstream GitHub repo (default: one-observability-demo). */
  readonly upstreamRepo?: string;
  /**
   * Upstream git ref to pin the petsite build to: a branch, a tag, or a full
   * 40-character commit SHA (an abbreviated SHA is not fetchable and fails the
   * container build). bin/app.ts always passes upstream.ref from
   * config/accounts.json, which is pinned to a full SHA; the `main` fallback
   * below only applies when this stack is instantiated directly.
   */
  readonly upstreamRef?: string;
  /**
   * SSM parameter name for autoscaling max capacity.
   * Default: /aiops-poc/workload/petsite-max-capacity
   */
  readonly maxCapacitySsmParam?: string;
  /**
   * Override max capacity directly (for testing without SSM lookups).
   * When set, bypasses SSM parameter resolution.
   */
  readonly maxCapacityOverride?: number;
  /**
   * Override the CloudFront origin-facing managed prefix list ID
   * (for testing without EC2 context lookups). When set, bypasses
   * `ec2.PrefixList.fromLookup`.
   */
  readonly cfPrefixListIdOverride?: string;
  /**
   * SSM parameter name holding the BE PrivateLink endpoint service name
   * (synced from BE by sync-outputs.sh before this stack deploys).
   * Default: /aiops-poc/workload/petsite-privatelink-service-name
   */
  readonly privatelinkServiceNameSsmParam?: string;
  /**
   * Override the PrivateLink endpoint service name directly (for testing
   * without SSM lookups). When set, bypasses
   * `ssm.StringParameter.valueFromLookup`.
   */
  readonly privatelinkServiceNameOverride?: string;
}

/**
 * FrontendStack deploys petsite from unmodified upstream source on
 * ECS Fargate behind a public ALB with autoscaling.
 *
 * Autoscaling max-capacity is driven by SSM parameter
 * `/aiops-poc/workload/petsite-max-capacity` to enable the `ui-no-scale`
 * chaos scenario (pin max to current to block scale-out).
 *
 * The ALB is fronted by CloudFront; its security group only allows traffic
 * from the CloudFront origin-facing managed prefix list, so the ALB is not
 * directly reachable from the public internet.
 *
 * The stack publishes the petsite CloudFront URL to SSM for downstream
 * consumers.
 */
export class FrontendStack extends cdk.Stack {
  /** The public petsite URL (CloudFront distribution). */
  public readonly petsiteUrl: string;
  /** The ECS Fargate service. */
  public readonly service: ecs_patterns.ApplicationLoadBalancedFargateService;

  constructor(scope: Construct, id: string, props: FrontendStackProps) {
    super(scope, id, props);

    const upstreamOrg = props.upstreamOrg ?? 'aws-samples';
    const upstreamRepo = props.upstreamRepo ?? 'one-observability-demo';
    const upstreamRef = props.upstreamRef ?? 'main';
    const maxCapacitySsmParam = props.maxCapacitySsmParam ??
      '/aiops-poc/workload/petsite-max-capacity';

    // --- VPC ---
    const vpc = new ec2.Vpc(this, 'PetsiteVpc', {
      maxAzs: 2,
      natGateways: 1,
    });

    // --- ECS Cluster ---
    const cluster = new ecs.Cluster(this, 'PetsiteCluster', {
      vpc,
      clusterName: 'aiops-poc-petsite',
    });

    // --- Petsite Container Image (built from upstream source) ---
    // Build for ARM64 to match the Fargate runtimePlatform below. The image is
    // built on the local Docker host; pinning the platform keeps the built
    // image architecture consistent with the Fargate CPU architecture and
    // avoids "exec format error" crashes from an arch mismatch.
    const image = ecs.ContainerImage.fromAsset(
      path.join(__dirname, '..', 'docker'),
      {
        buildArgs: {
          UPSTREAM_ORG: upstreamOrg,
          UPSTREAM_REPO: upstreamRepo,
          UPSTREAM_REF: upstreamRef,
        },
        platform: Platform.LINUX_ARM64,
      },
    );

    // --- ALB + Fargate Service ---
    this.service = new ecs_patterns.ApplicationLoadBalancedFargateService(
      this,
      'PetsiteService',
      {
        cluster,
        serviceName: 'petsite',
        taskImageOptions: {
          image,
          containerPort: 80,
          environment: {
            ASPNETCORE_URLS: 'http://+:80',
            // petsite loads config from SSM (/petstore prefix) via
            // Amazon.Extensions.Configuration.SystemsManager at startup. Fargate
            // does not set a default AWS region env var, so the SSM client
            // construction fails with "No RegionEndpoint or ServiceURL
            // configured". Provide the region explicitly.
            AWS_REGION: this.region,
            AWS_DEFAULT_REGION: this.region,
            // petsite resolves SSM parameter NAMES from environment variables
            // at request time (Configuration/ParameterNames.cs upstream) and
            // prepends PARAMETER_STORE_PREFIX (default /petstore) to each
            // leaf name. This mapping mirrors upstream's canonical petsite
            // deployment (src/cdk/lib/microservices/petsite.ts +
            // manifests/petsite-deployment.yaml + bin/constants.ts).
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
          },
        },
        publicLoadBalancer: true,
        // Do NOT open the listener to 0.0.0.0/0 — the ALB only accepts
        // traffic from CloudFront origin-facing IPs (see ingress rule below).
        openListener: false,
        desiredCount: 2,
        cpu: 512,
        memoryLimitMiB: 1024,
        assignPublicIp: false,
        // Match the ARM64 image built above (avoids exec format error).
        runtimePlatform: {
          cpuArchitecture: ecs.CpuArchitecture.ARM64,
          operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
        },
      },
    );

    // Health check on the target group
    this.service.targetGroup.configureHealthCheck({
      path: '/',
      healthyHttpCodes: '200-399',
    });

    // Drift recovery: the original HTTP:80 listener was deleted out-of-band
    // by a security auto-mitigation. CloudFormation does not reconcile
    // deleted resources whose properties are unchanged, so we rename the
    // listener's logical ID to force creation of a fresh listener.
    const cfnListener = this.service.listener.node.defaultChild as cdk.CfnResource;
    cfnListener.overrideLogicalId('PetsiteServiceLBPublicListenerV2');

    // ================================================================
    // Security: restrict ALB ingress to CloudFront origin-facing IPs
    // The ALB is internet-facing but only reachable through CloudFront,
    // via the AWS-managed prefix list
    // `com.amazonaws.global.cloudfront.origin-facing`.
    // ================================================================
    const cfPrefixListId = props.cfPrefixListIdOverride ??
      ec2.PrefixList.fromLookup(this, 'CloudFrontOriginFacing', {
        prefixListName: 'com.amazonaws.global.cloudfront.origin-facing',
      }).prefixListId;

    this.service.loadBalancer.connections.allowFrom(
      ec2.Peer.prefixList(cfPrefixListId),
      ec2.Port.tcp(80),
      'Allow CloudFront origin-facing traffic only',
    );

    // ================================================================
    // CloudFront distribution fronting the ALB
    // Caching disabled + all-viewer origin request policy: petsite is a
    // dynamic app, CloudFront is here for access control (TLS + managed
    // edge), not caching.
    // ================================================================
    const distribution = new cloudfront.Distribution(this, 'PetsiteDistribution', {
      comment: 'aiops-poc petsite (fronts the ALB; ALB is not publicly reachable)',
      defaultBehavior: {
        origin: new origins.LoadBalancerV2Origin(this.service.loadBalancer, {
          protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
          httpPort: 80,
        }),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
      },
    });

    // petsite reads its configuration from SSM under the /petstore prefix at
    // startup (via Amazon.Extensions.Configuration.SystemsManager, using the
    // task role). Grant read access to those parameters so the SSM
    // configuration provider can load them.
    this.service.taskDefinition.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'PetstoreSsmRead',
      effect: iam.Effect.ALLOW,
      actions: [
        'ssm:GetParameter',
        'ssm:GetParameters',
        'ssm:GetParametersByPath',
      ],
      resources: [
        `arn:aws:ssm:${this.region}:${this.account}:parameter/petstore`,
        `arn:aws:ssm:${this.region}:${this.account}:parameter/petstore/*`,
      ],
    }));

    // Waggle chat: petsite invokes the PetFood agent — a Bedrock AgentCore
    // runtime deployed by the upstream in the BE account (its ARN reaches
    // petsite via the synced /petstore/petfoodagent-runtime-arn parameter).
    // Cross-account authorization is hierarchical: this identity policy must
    // allow InvokeAgentRuntime on BOTH the runtime and its endpoint, and the
    // BE side attaches matching resource policies to both (BackendOverlayStack).
    // The name-wildcard scoping mirrors the upstream's own petsite policy
    // (src/cdk/lib/microservices/petsite.ts: runtime/PetFoodAgent*), which
    // also covers endpoint ARNs (<runtime-arn>/runtime-endpoint/DEFAULT).
    this.service.taskDefinition.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
      sid: 'PetfoodAgentInvoke',
      effect: iam.Effect.ALLOW,
      actions: ['bedrock-agentcore:InvokeAgentRuntime'],
      resources: [
        `arn:aws:bedrock-agentcore:${this.region}:${props.backendAccountId}:runtime/PetFoodAgent*`,
      ],
    }));

    // --- Autoscaling with SSM-driven max capacity ---
    // Resolve max capacity: use override for testing, otherwise SSM at deploy time
    let maxCapacity: number;
    if (props.maxCapacityOverride !== undefined) {
      maxCapacity = props.maxCapacityOverride;
    } else {
      // Deploy-time SSM resolution with a default of 4
      const maxCapacityValue = ssm.StringParameter.valueFromLookup(
        this,
        maxCapacitySsmParam,
      );
      // valueFromLookup returns 'dummy-value-for-...' during synth without context
      maxCapacity = maxCapacityValue.startsWith('dummy') ? 4 : parseInt(maxCapacityValue, 10) || 4;
    }

    const scaling = this.service.service.autoScaleTaskCount({
      minCapacity: 2,
      maxCapacity,
    });

    scaling.scaleOnCpuUtilization('CpuScaling', {
      targetUtilizationPercent: 70,
      scaleInCooldown: cdk.Duration.seconds(60),
      scaleOutCooldown: cdk.Duration.seconds(60),
    });

    scaling.scaleOnRequestCount('RequestScaling', {
      requestsPerTarget: 1000,
      targetGroup: this.service.targetGroup,
      scaleInCooldown: cdk.Duration.seconds(60),
      scaleOutCooldown: cdk.Duration.seconds(60),
    });

    // --- Publish the petsite URL (CloudFront) to SSM ---
    // Downstream consumers (canary, loadgen) go through CloudFront; the ALB
    // is not directly reachable from the public internet.
    this.petsiteUrl = `https://${distribution.distributionDomainName}`;

    new ssm.StringParameter(this, 'PetsiteUrlParam', {
      parameterName: '/aiops-poc/workload/petsite-url',
      stringValue: this.petsiteUrl,
      description: 'Public URL for petsite (CloudFront distribution)',
    });

    // --- Create the SSM parameter for max-capacity (seed with default) ---
    // This SSM parameter is what chaos tooling mutates for ui-no-scale
    new ssm.StringParameter(this, 'PetsiteMaxCapacityParam', {
      parameterName: maxCapacitySsmParam,
      stringValue: String(maxCapacity),
      description: 'Max autoscaling capacity for petsite (mutated by ui-no-scale chaos)',
    });

    // --- Publish the FE ECS cluster + service names to SSM ---
    // The chaos tooling (ui-no-scale in chaos/scripts/inject.sh/restore.sh)
    // resolves these at runtime instead of hardcoding names — SSM is the
    // project's parameter contract (docs/parameters.md).
    new ssm.StringParameter(this, 'FeEcsClusterParam', {
      parameterName: '/aiops-poc/workload/fe-ecs-cluster',
      stringValue: cluster.clusterName,
      description: 'FE ECS cluster name hosting petsite (chaos ui-no-scale target)',
    });

    new ssm.StringParameter(this, 'FeEcsServiceParam', {
      parameterName: '/aiops-poc/workload/fe-ecs-service',
      stringValue: this.service.service.serviceName,
      description: 'FE ECS service name for petsite (chaos ui-no-scale target)',
    });

    // ================================================================
    // FE → BE private connectivity via AWS PrivateLink
    //
    // The FE and BE VPCs both use 10.0.0.0/16 (overlapping CIDRs), so
    // peering is impossible. The BE overlay exposes the internal petsearch,
    // petlistadoption, petfood and payforadoption ALBs through an NLB +
    // VPC Endpoint Service; this stack creates the consuming interface
    // endpoint:
    //   endpoint :80   → petsearch        (searchapiurl)
    //   endpoint :8080 → petlistadoption  (petlistadoptionsurl)
    //   endpoint :8081 → petfood          (petfoodapiurl, petfoodcarturl)
    //   endpoint :8082 → payforadoption   (paymentapiurl, cleanupadoptionsurl)
    // ================================================================

    const privatelinkSsmParam = props.privatelinkServiceNameSsmParam ??
      '/aiops-poc/workload/petsite-privatelink-service-name';

    let privatelinkServiceName: string;
    if (props.privatelinkServiceNameOverride !== undefined) {
      privatelinkServiceName = props.privatelinkServiceNameOverride;
    } else {
      // Deploy-time SSM resolution (param synced from BE by sync-outputs.sh).
      // valueFromLookup returns 'dummy-value-for-...' during synth without
      // context — substitute a syntactically plausible placeholder so synth
      // (and tests) succeed; real deploys resolve the actual service name.
      const lookedUp = ssm.StringParameter.valueFromLookup(this, privatelinkSsmParam);
      privatelinkServiceName = lookedUp.startsWith('dummy')
        ? 'com.amazonaws.vpce.placeholder.vpce-svc-00000000000000000'
        : lookedUp;
    }

    // Dedicated SG for the endpoint ENIs: only petsite tasks may reach the
    // BE services, on the two PrivateLink ports.
    const petsiteServiceSg = this.service.service.connections.securityGroups[0];

    const privatelinkEndpointSg = new ec2.SecurityGroup(this, 'PetsiteBackendEndpointSg', {
      vpc,
      description: 'PrivateLink endpoint to BE petsearch/petlistadoption (petsite only)',
      allowAllOutbound: true,
    });

    // NOTE: EC2 restricts SG rule descriptions to the character set
    // [a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*]. Neither the Unicode arrow (→) NOR
    // the ASCII ">" is allowed, so a description like "petsite -> petsearch"
    // fails the whole stack with "Invalid rule description". Use plain words.
    privatelinkEndpointSg.addIngressRule(
      petsiteServiceSg,
      ec2.Port.tcp(80),
      'petsite to petsearch via PrivateLink',
    );

    privatelinkEndpointSg.addIngressRule(
      petsiteServiceSg,
      ec2.Port.tcp(8080),
      'petsite to petlistadoption via PrivateLink',
    );

    privatelinkEndpointSg.addIngressRule(
      petsiteServiceSg,
      ec2.Port.tcp(8081),
      'petsite to petfood via PrivateLink',
    );

    privatelinkEndpointSg.addIngressRule(
      petsiteServiceSg,
      ec2.Port.tcp(8082),
      'petsite to payforadoption via PrivateLink',
    );

    const backendEndpoint = new ec2.InterfaceVpcEndpoint(this, 'PetsiteBackendEndpoint', {
      vpc,
      service: new ec2.InterfaceVpcEndpointService(privatelinkServiceName),
      privateDnsEnabled: false,
      subnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroups: [privatelinkEndpointSg],
      // Ingress is managed explicitly above (80 + 8080 from the petsite SG);
      // `open: true` would add a default rule on the service port instead.
      open: false,
    });

    // Regional endpoint DNS name. Entries are "<hosted-zone-id>:<dns-name>";
    // the first entry is the regional (AZ-agnostic) name.
    const backendEndpointDns = cdk.Fn.select(
      1,
      cdk.Fn.split(':', cdk.Fn.select(0, backendEndpoint.vpcEndpointDnsEntries)),
    );

    // ================================================================
    // SSM URL parameters for petsite native service discovery
    // These are the native PetAdoptions mechanism — petsite reads these
    // at startup to find BE endpoints.
    //   - searchapiurl / petlistadoptionsurl / petfoodapiurl /
    //     petfoodcarturl / cleanupadoptionsurl / paymentapiurl are OWNED
    //     BY THIS STACK and point at the PrivateLink interface endpoint
    //     above.
    //   - updateadoptionstatusurl is a public API Gateway URL;
    //     placeholder here, populated by sync-outputs.sh.
    // Trailing formats matter: search ends with '?', adoptionlist with '/',
    // petfood paths end WITHOUT a trailing slash ('/api/foods', '/api/cart')
    // — these mirror the exact BE /petstore values with only host:port
    // swapped (petsite string-concatenates onto these values).
    // ================================================================

    new ssm.StringParameter(this, 'SsmSearchApiUrl', {
      parameterName: '/petstore/searchapiurl',
      stringValue: `http://${backendEndpointDns}/api/search?`,
      description: 'PetSearch API URL (BE via PrivateLink interface endpoint)',
    });

    new ssm.StringParameter(this, 'SsmPetListAdoptionsUrl', {
      parameterName: '/petstore/petlistadoptionsurl',
      stringValue: `http://${backendEndpointDns}:8080/api/adoptionlist/`,
      description: 'PetListAdoptions URL (BE via PrivateLink interface endpoint)',
    });

    new ssm.StringParameter(this, 'SsmUpdateAdoptionStatusUrl', {
      parameterName: '/petstore/updateadoptionstatusurl',
      stringValue: 'http://placeholder-updateadoptionstatus.internal',
      description: 'UpdateAdoptionStatus URL (populated by sync-outputs.sh from BE)',
    });

    // Petfood API + cart run on the same BE internal ALB (LB-petfood-rs),
    // exposed via PrivateLink on :8081. The BE values are
    // http://<internal-alb>/api/foods and http://<internal-alb>/api/cart —
    // mirror those path shapes exactly, swapping only host:port.
    new ssm.StringParameter(this, 'SsmPetFoodApiUrl', {
      parameterName: '/petstore/petfoodapiurl',
      stringValue: `http://${backendEndpointDns}:8081/api/foods`,
      description: 'PetFood API URL (BE via PrivateLink interface endpoint)',
    });

    new ssm.StringParameter(this, 'SsmPetFoodCartUrl', {
      parameterName: '/petstore/petfoodcarturl',
      stringValue: `http://${backendEndpointDns}:8081/api/cart`,
      description: 'PetFood cart URL (BE via PrivateLink interface endpoint)',
    });

    // The cleanup route ("Perform Housekeeping") is served by
    // payforadoption-go on the BE internal ALB (LB-payforadoption-go),
    // exposed via PrivateLink on :8082. The BE value is
    // http://<internal-alb>/api/cleanupadoptions (petsite appends
    // '/<userId>' and issues DELETE) — mirror that path shape exactly,
    // swapping only host:port. Without this, petsite times out against
    // the unreachable BE-internal ALB and CloudFront returns 504.
    new ssm.StringParameter(this, 'SsmCleanupAdoptionsUrl', {
      parameterName: '/petstore/cleanupadoptionsurl',
      stringValue: `http://${backendEndpointDns}:8082/api/cleanupadoptions`,
      description: 'CleanupAdoptions URL (BE via PrivateLink interface endpoint)',
    });

    // ─────────────────────────────────────────────────────────────────────
    // PCI DSS — scope and customer responsibility
    //
    // The parameters below wire up a checkout/"payment" flow, and the
    // golden-journey canary drives it end to end. In this PoC that flow is
    // entirely synthetic: the upstream PetAdoptions payforadoption-go service
    // records an adoption transaction and NEVER handles cardholder data — no
    // PAN, no CVV, no payment credentials are collected, transmitted or
    // stored, and no payment processor is integrated.
    //
    // If you adapt this sample into a workload that DOES process, transmit or
    // store cardholder data, PCI DSS applies and the cardholder data
    // environment becomes yours to define and validate. Under the AWS shared
    // responsibility model, AWS's PCI DSS attestation covers the security OF
    // the cloud; your application, its data flows, network segmentation, key
    // management, logging and retention are security IN the cloud and remain
    // your responsibility. Neither this template nor this PoC is a compliant
    // reference architecture for cardholder data.
    //   https://aws.amazon.com/compliance/pci-dss-level-1-faqs/
    //   https://aws.amazon.com/compliance/shared-responsibility-model/
    // ─────────────────────────────────────────────────────────────────────

    // The adopt/checkout flow ("Take me home", PAYMENT_API_URL_PARAM_NAME)
    // is served by payforadoption-go on the same BE internal ALB
    // (LB-payforadoption-go), exposed via PrivateLink on :8082. The BE value
    // is http://<internal-alb>/api/completeadoption (no trailing slash;
    // petsite appends '?petId=..&petType=..' and POSTs) — mirror that path
    // shape exactly, swapping only host:port. Without this, petsite times
    // out against the unreachable BE-internal ALB and CloudFront returns
    // 504. (The legacy /petstore/payforadoptionurl placeholder was removed:
    // petsite only reads paymentapiurl for this flow.)
    new ssm.StringParameter(this, 'SsmPaymentApiUrl', {
      parameterName: '/petstore/paymentapiurl',
      stringValue: `http://${backendEndpointDns}:8082/api/completeadoption`,
      description: 'PayForAdoption payment API URL (BE via PrivateLink interface endpoint)',
    });

    // ================================================================
    // FE Incidents SNS topic with cross-account topic policy
    // ================================================================

    const feIncidentsTopic = new sns.Topic(this, 'FeIncidentsTopic', {
      topicName: 'aiops-poc-fe-incidents',
      displayName: 'AIOps PoC Frontend Incidents',
    });

    // Allow the OPS account to subscribe and receive messages
    feIncidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowOpsAccountSubscribe',
      effect: iam.Effect.ALLOW,
      principals: [new iam.AccountPrincipal(props.opsAccountId)],
      actions: ['sns:Subscribe', 'sns:Receive'],
      resources: [feIncidentsTopic.topicArn],
    }));

    // CloudWatch alarm actions (same-account) need sns:Publish — the
    // cross-account subscribe policy replaced the default and dropped it
    // (fixed 2026-07-27). Scope the grant to the CloudWatch service
    // principal in THIS account (the topic's own account) via aws:SourceAccount.
    feIncidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowCloudWatchAlarmPublish',
      effect: iam.Effect.ALLOW,
      principals: [new iam.ServicePrincipal('cloudwatch.amazonaws.com')],
      actions: ['sns:Publish'],
      resources: [feIncidentsTopic.topicArn],
      conditions: {
        StringEquals: { 'aws:SourceAccount': this.account },
      },
    }));

    // Restore the account-owner publish/management grant that the custom
    // policy above dropped when it replaced the SNS default (fixed 2026-07-27).
    feIncidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowOwnerPublish',
      effect: iam.Effect.ALLOW,
      principals: [new iam.AccountPrincipal(this.account)],
      actions: ['sns:Publish'],
      resources: [feIncidentsTopic.topicArn],
    }));

    // ================================================================
    // CloudWatch Synthetics journey canary
    // Performs the shopper journey: browse → search → view pet → adopt
    // ================================================================

    // DETECTION-SPEED JUSTIFICATION (measured 2026-07-28, live validation)
    // ------------------------------------------------------------------
    // With a 5-minute canary and 2×300s journey alarms, the FE golden signal
    // fired 17m37s AFTER the BE infrastructure task-count alarm — inverting
    // the demo's whole teaching point ("customer-facing golden signals detect
    // before infra metrics"). The cause was sampling asymmetry, not
    // thresholds: the journey path had a >=10 min floor (2 canary runs at
    // 5 min) while BE RunningTaskCount evaluates 2×60s (~2-4 min).
    // Fix: run the canary EVERY MINUTE and alarm on 1-of-2 60s datapoints
    // (see the journey alarms below) → ~1-2 min detection, so the golden
    // signal now fires first.
    const journeyCanary = new synthetics.Canary(this, 'JourneyCanary', {
      canaryName: 'aiops-poc-journey',
      runtime: synthetics.Runtime.SYNTHETICS_NODEJS_PUPPETEER_9_1,
      // 1 minute is the fastest Synthetics rate; it sets the detection floor
      // for both journey alarms below.
      schedule: synthetics.Schedule.rate(cdk.Duration.minutes(1)),
      test: synthetics.Test.custom({
        code: synthetics.Code.fromInline(`
const { URL } = require('url');
const synthetics = require('Synthetics');
const log = require('SyntheticsLogger');

// The journey exercises petsite's REAL routes, which are the ones backed by
// the FE->BE PrivateLink path:
//   /                                  homepage (HomeController.Index)
//   /?selectedPetType=..&selectedPetColor=..  search (petsearch-java via PrivateLink :80)
//   /PetListAdoptions?userId=..        adoption list (petlistadoption-py via PrivateLink :8080)
//   /housekeeping + /Adoption + /Payment/MakePayment   CHECKOUT
//                                      (payforadoption-go via PrivateLink :8082)
// The previous blueprint used /search, /pet/1 and /adopt, which do not exist
// in this petsite (they 404) — the canary failed at "Search page returned
// status 404" on every run.
//
// Step 4 (checkout) was added 2026-07-27: without it the FE was blind to a
// payments outage (verified: FE 5xx = 0 during a full payforadoption outage,
// because nothing on the FE ever called the payment service).
const pageLoadBlueprint = async function () {
  const baseUrl = process.env.PETSITE_URL;
  const userId = 'canary-user';
  log.info('Starting shopper journey canary against: ' + baseUrl);

  // Step 1: Browse homepage (follows the userId-assignment redirect)
  let page = await synthetics.getPage();
  const response = await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (response.status() >= 400) {
    throw new Error('Homepage returned status ' + response.status());
  }
  log.info('Step 1 - Browse homepage: PASSED');

  // Step 2: Search for pets — search runs on '/' via query params, not '/search'
  const searchUrl = new URL('/?selectedPetType=puppy&selectedPetColor=brown', baseUrl).href;
  const searchResponse = await page.goto(searchUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (searchResponse && searchResponse.status() >= 400) {
    throw new Error('Search page returned status ' + searchResponse.status());
  }
  // CONTENT CHECK (mirrors step 4a). petsite MASKS a dead/degraded petsearch as
  // a FAST HTTP 200 error page: when the search backend is gone its ALB returns
  // 503, petsite catches it server-side and renders "Unable to search pets at
  // this time…" with HTTP 200, so the status check above passes and the canary
  // is BLIND. Verified 2026-07-28 search-crash run: petsearch-java held at 0
  // tasks for a full outage, petsite returned 200 + the error page, and 19/19
  // canary runs PASSED — no golden alarm ever fired (detection gap B4).
  //
  // Fix: after the status check, assert the search RESULTS actually rendered.
  // A healthy puppy/brown search server-renders multiple pet result cards, each
  // a "Take me home" adopt form with a hidden petid input
  // (name="petid" / id="pet_petid" / action="/adoption/takemehome" /
  // class="pet-thumbnail"); the error page and a genuine zero-results page have
  // NONE of these. The assertion keys on RESULT markup only — never on the
  // search form's dropdown, whose <option> values also contain "puppy"/"brown"
  // and would false-pass. puppy/brown has stable seed data (6 result cards
  // measured 2026-07-28), so an absent result marker reliably means the search
  // path failed, not markup drift.
  // NOTE: markers are deliberately slash-free — this regex literal lives inside
  // a template-literal string, so any '\/' escaping would be stripped when the
  // canary source string is built, breaking the regex. 'takemehome' is the
  // adopt-form action ('/adoption/takemehome') minus its slashes and still only
  // appears in result cards.
  const searchBody = await page.content();
  const hasSearchResults = /name="petid"|id="pet_petid"|pet-thumbnail|takemehome/i.test(searchBody);
  if (!hasSearchResults) {
    throw new Error('Search returned no results — petsearch dependency unavailable/degraded');
  }
  log.info('Step 2 - Search for pets: PASSED');

  // Step 3: View the adoption list (petlistadoption via PrivateLink)
  const listUrl = new URL('/PetListAdoptions?userId=' + userId, baseUrl).href;
  const listResponse = await page.goto(listUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (listResponse && listResponse.status() >= 400) {
    throw new Error('PetListAdoptions page returned status ' + listResponse.status());
  }
  log.info('Step 3 - View adoption list: PASSED');

  // Step 4: CHECKOUT — the only FE path that reaches payforadoption-go
  // (PrivateLink :8082). Two parts, both driven from the REAL petsite markup:
  //
  //   4a  GET /housekeeping?userId=..  -> petsite DELETEs
  //       <paymentsvc>/api/cleanupadoptions/<userId> (cleanupadoptionsurl).
  //       This is a GET that server-side calls the payment service, and it
  //       also resets pet availability so 4b can always adopt.
  //   4b  GET /Adoption/Index?petid=..&userId=..  then submit the real
  //       "Pay and Adopt" form (action="/Payment/MakePayment") -> petsite
  //       POSTs <paymentsvc>/api/completeadoption?petId=..&petType=..
  //       (paymentapiurl). This is the customer's actual checkout.
  //
  // WHY BOTH: petsite swallows HTTP error STATUSES from the payment API on
  // the checkout POST — PaymentController.MakePayment awaits PostAsync
  // without EnsureSuccessStatusCode, so a 500/503 from payforadoption still
  // redirects to /Payment/Index?status=success. Only an exception (timeout /
  // connection failure) surfaces there. The housekeeping route DOES check
  // response.IsSuccessStatusCode and renders an explicit error message, so
  // 4a is what catches the "payments-error" (HTTP 500s) fault while 4b
  // catches hangs/latency and exercises the real checkout path end to end.
  //
  // TRADE-OFF (accepted, re-evaluated 2026-07-28 when the cadence went to
  // 1 minute): 4a MUTATES data — cleanupadoptions resets pet availability and
  // drops adoption transactions globally — and 4b adopts one pet per run.
  // At the 1-minute cadence that is ~60 resets + ~60 adoptions per hour
  // (was ~12 + ~12 at 5 min).
  //
  // No non-mutating alternative exists. Verified against upstream petsite
  // source (src/applications/microservices/petsite-net/petsite): the payment
  // service parameters are read at exactly two call sites —
  // HomeController.HouseKeeping (CLEANUP_ADOPTIONS_URL, DELETE) and
  // PaymentController.MakePayment (PAYMENT_API_URL, POST). Every other
  // controller talks to petsearch, petlistadoption or petfood/cart, so there
  // is NO read-only petsite route whose request reaches payforadoption-go.
  // Keeping 4a is therefore the only way for the FE golden signal to see a
  // payments outage at all.
  //
  // The reset itself is the same operation the upstream housekeeping canary
  // performs on its own schedule (BE), so this only increases its frequency;
  // the cost is that adoption history never accumulates between runs, which
  // is also what keeps 4b's adoption idempotent.
  const housekeepingUrl = new URL('/housekeeping?userId=' + userId, baseUrl).href;
  const hkResponse = await page.goto(housekeepingUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  // Assert on >= 500 only: a server error is a real customer-facing failure,
  // while a 4xx (e.g. an antiforgery/redirect quirk or a bad synthetic
  // userId) is a client-side condition that must NOT page a human.
  if (hkResponse && hkResponse.status() >= 500) {
    throw new Error('Housekeeping (payment service) returned status ' + hkResponse.status());
  }
  // petsite renders the cleanup failure as page content with HTTP 200, so the
  // only reliable signal is the controller's own error text (HomeController
  // .HouseKeeping: "Housekeeping operation failed..." / "Unable to perform
  // housekeeping..."), shown in a Bootstrap alert-danger block.
  const hkBody = await page.content();
  if (/Housekeeping operation failed|Unable to perform housekeeping|alert-danger/i.test(hkBody)) {
    throw new Error('Payment service (payforadoption) reported a failure on the cleanup/checkout path');
  }
  log.info('Step 4a - Payment service reachable (housekeeping/cleanup): PASSED');

  // 4b: real checkout. petid '001' is a seeded pet; availability was just
  // reset by 4a, so the adoption is expected to succeed.
  const adoptUrl = new URL('/Adoption/Index?petid=001&userId=' + userId, baseUrl).href;
  const adoptResponse = await page.goto(adoptUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (adoptResponse && adoptResponse.status() >= 500) {
    throw new Error('Adoption/checkout page returned status ' + adoptResponse.status());
  }

  const payButton = await page.$('form[action="/Payment/MakePayment"] input[type="submit"]');
  if (!payButton) {
    throw new Error('Checkout form (Payment/MakePayment) not rendered on the adoption page');
  }

  const [payResponse] = await Promise.all([
    page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 30000 }),
    payButton.click(),
  ]);
  if (payResponse && payResponse.status() >= 500) {
    throw new Error('Checkout (Payment/MakePayment) returned status ' + payResponse.status());
  }
  // Payment/Index renders "Adoption Complete" on success and
  // "Sorry, something went wrong" when the payment call threw.
  const payBody = await page.content();
  if (/Sorry, something went wrong/i.test(payBody)) {
    throw new Error('Checkout failed: petsite could not complete the adoption (payment API)');
  }
  if (!/Adoption Complete/i.test(payBody)) {
    // Markup drift alone must not page anyone — the hard signals above
    // (>= 500, explicit failure text) already cover real outages.
    log.warn('Step 4b - checkout success marker not found; page may have changed upstream');
  }
  log.info('Step 4b - Checkout (Pay and Adopt via payment API): PASSED');

  log.info('Shopper journey completed successfully');
};

exports.handler = async () => {
  return await pageLoadBlueprint();
};
`),
        handler: 'index.handler',
      }),
      environmentVariables: {
        PETSITE_URL: this.petsiteUrl,
      },
    });

    // ================================================================
    // FE GOLDEN-SIGNAL ALARMS (these PAGE) vs BE INFRASTRUCTURE ALARMS
    //
    // Split, by design:
    //   * FE (this stack) owns the CUSTOMER-FACING golden signals —
    //     availability (5xx error rate), latency, and the shopper journey
    //     canary. They all action the FE incidents topic, i.e. they page the
    //     app-team first responder.
    //   * BE owns INFRASTRUCTURE alarms (ECS task counts, target health, DB,
    //     queue depth). Those have NO alarm actions: they are evidence for
    //     the diagnosis, not a pager.
    //
    // The teaching point of the demo is the ORDER: the golden signal fires
    // FIRST, then the agent correlates the BE infra alarms to explain WHY.
    //
    // MEASURED REGRESSION + FIX (live validation 2026-07-28): the golden
    // signal LOST the race by 17m37s — the BE RunningTaskCount infra alarm
    // (2×60s, ~2-4 min) beat the journey alarms, which sat on 2×300s
    // datapoints fed by a 5-minute canary (>=10 min floor). Sampling
    // asymmetry, not thresholds. Fix applied here:
    //   * canary schedule 5 min → 1 min (see JourneyCanary above)
    //   * journey alarms 300s/2-of-2 → 60s period, evaluationPeriods 2,
    //     datapointsToAlarm 1 (M-of-N). 1-of-2 fires on the FIRST failing
    //     canary run (~1-2 min, beating the 2×60s infra alarms) while the
    //     2-period window keeps the RECOVERY direction tolerant of a single
    //     flake (the alarm only clears after both periods are healthy).
    //
    // NAMING (2026-07-28): FE alarm names encode tier + class —
    // `aiops-poc-fe-golden-*` — so an investigation title is
    // self-describing. Before, a title read "aiops-poc-adoption-error-rate is
    // ALARM" with no hint of which tier or signal class it came from.
    // ================================================================

    // Petsite ALB error rate — the customer-facing availability golden signal.
    // `loadBalancerFullName` IS the CloudWatch `LoadBalancer` dimension value
    // (app/<name>/<id>), so no ARN parsing is needed.
    const albDimensions = { LoadBalancer: this.service.loadBalancer.loadBalancerFullName };

    const albTarget5xx = new cloudwatch.Metric({
      namespace: 'AWS/ApplicationELB',
      metricName: 'HTTPCode_Target_5XX_Count',
      dimensionsMap: albDimensions,
      statistic: 'Sum',
      period: cdk.Duration.seconds(60),
    });

    const albElb5xx = new cloudwatch.Metric({
      namespace: 'AWS/ApplicationELB',
      metricName: 'HTTPCode_ELB_5XX_Count',
      dimensionsMap: albDimensions,
      statistic: 'Sum',
      period: cdk.Duration.seconds(60),
    });

    const albRequests = new cloudwatch.Metric({
      namespace: 'AWS/ApplicationELB',
      metricName: 'RequestCount',
      dimensionsMap: albDimensions,
      statistic: 'Sum',
      period: cdk.Duration.seconds(60),
    });

    const feCheckoutErrorRateAlarm = new cloudwatch.Alarm(this, 'FeCheckoutErrorRateAlarm', {
      alarmName: 'aiops-poc-fe-golden-checkout-error-rate',
      alarmDescription:
        'CUSTOMER-FACING GOLDEN SIGNAL: petsite ALB 5xx error rate > 2% ' +
        '(target 5xx + ELB 5xx over requests, 2×60s). Covers the checkout ' +
        'path; pages the app-team first responder. BE infrastructure alarms ' +
        'are evidence only and do not page.',
      metric: new cloudwatch.MathExpression({
        expression: '(target5xx + elb5xx) / requests * 100',
        usingMetrics: {
          target5xx: albTarget5xx,
          elb5xx: albElb5xx,
          requests: albRequests,
        },
        label: 'petsite 5xx error rate (%)',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 2,
      evaluationPeriods: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      // No requests in a period yields no data — quiet periods must not alarm.
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    feCheckoutErrorRateAlarm.addAlarmAction(new cw_actions.SnsAction(feIncidentsTopic));

    // ================================================================
    // Journey SLO alarms: SuccessPercent < 90% OR Duration > 10000ms,
    // both on 60s periods with 1-of-2 datapoints (see the speed rationale
    // above). The canary runs every minute, so one failing run alarms.
    //
    // The metric dimension stays `CanaryName: aiops-poc-journey` — the
    // CANARY was NOT renamed, only the alarms.
    // ================================================================

    const journeySuccessAlarm = new cloudwatch.Alarm(this, 'JourneySuccessAlarm', {
      alarmName: 'aiops-poc-fe-golden-journey-success',
      alarmDescription:
        'CUSTOMER-FACING GOLDEN SIGNAL: shopper journey canary SuccessPercent ' +
        '< 90% (1 of 2×60s datapoints, canary runs every minute → ~1-2 min ' +
        'detection). The journey includes the CHECKOUT path ' +
        '(payforadoption via PrivateLink :8082), so this also detects a ' +
        'payments outage. Pages the app-team first responder.',
      metric: new cloudwatch.Metric({
        namespace: 'CloudWatchSynthetics',
        metricName: 'SuccessPercent',
        dimensionsMap: { CanaryName: 'aiops-poc-journey' },
        statistic: 'Average',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 90,
      // 1-of-2 at 60s: alarms on the first failing canary run (fast enough to
      // beat the 2×60s BE infra alarms), yet needs two clean periods to
      // return to OK, which absorbs a single flake on the recovery side.
      evaluationPeriods: 2,
      datapointsToAlarm: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    journeySuccessAlarm.addAlarmAction(new cw_actions.SnsAction(feIncidentsTopic));

    const journeyDurationAlarm = new cloudwatch.Alarm(this, 'JourneyDurationAlarm', {
      alarmName: 'aiops-poc-fe-golden-journey-duration',
      alarmDescription:
        'CUSTOMER-FACING GOLDEN SIGNAL: shopper journey canary Duration > ' +
        '10000ms (1 of 2×60s datapoints, canary runs every minute → ~1-2 min ' +
        'detection). The journey includes the CHECKOUT path, so ' +
        'payment-service latency (checkout-degraded) shows up here. Pages ' +
        'the app-team first responder.',
      metric: new cloudwatch.Metric({
        namespace: 'CloudWatchSynthetics',
        metricName: 'Duration',
        dimensionsMap: { CanaryName: 'aiops-poc-journey' },
        statistic: 'Average',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 10000, // milliseconds
      // Same 1-of-2 at 60s M-of-N rationale as the success alarm above.
      evaluationPeriods: 2,
      datapointsToAlarm: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    journeyDurationAlarm.addAlarmAction(new cw_actions.SnsAction(feIncidentsTopic));

    // --- Stack outputs ---
    new cdk.CfnOutput(this, 'PetsiteAlbUrl', {
      value: this.petsiteUrl,
      description: 'Public petsite URL (CloudFront)',
      exportName: 'aiops-poc-petsite-url',
    });

    new cdk.CfnOutput(this, 'PetsiteCloudFrontUrl', {
      value: `https://${distribution.distributionDomainName}`,
      description: 'Petsite CloudFront distribution URL',
      exportName: 'aiops-poc-petsite-cloudfront-url',
    });

    new cdk.CfnOutput(this, 'PetsiteAlbDns', {
      value: this.service.loadBalancer.loadBalancerDnsName,
      description: 'Petsite ALB DNS name (not publicly reachable; debugging only)',
      exportName: 'aiops-poc-petsite-alb-dns',
    });

    new cdk.CfnOutput(this, 'PetsiteServiceArn', {
      value: this.service.service.serviceArn,
      description: 'Petsite ECS service ARN',
      exportName: 'aiops-poc-petsite-service-arn',
    });

    new cdk.CfnOutput(this, 'OpsAccountId', {
      value: props.opsAccountId,
      description: 'OPS account ID for cross-account policies',
      exportName: 'aiops-poc-fe-ops-account-id',
    });

    new cdk.CfnOutput(this, 'FeIncidentsTopicArn', {
      value: feIncidentsTopic.topicArn,
      description: 'Frontend incidents SNS topic ARN',
      exportName: 'aiops-poc-fe-incidents-topic-arn',
    });

    new cdk.CfnOutput(this, 'JourneyCanaryName', {
      value: journeyCanary.canaryName,
      description: 'Journey canary name',
      exportName: 'aiops-poc-journey-canary-name',
    });
  }
}
