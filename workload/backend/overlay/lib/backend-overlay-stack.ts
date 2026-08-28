import * as cdk from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cw_actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbv2_targets from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as fis from 'aws-cdk-lib/aws-fis';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';

/**
 * Configuration for the BackendOverlayStack.
 */
export interface BackendOverlayStackProps extends cdk.StackProps {
  /** The OPS account ID (for cross-account trust policies and topic policies). */
  readonly opsAccountId: string;
  /**
   * The FE account ID (allowed principal on the PrivateLink endpoint
   * service so the FE VPC can create an interface endpoint to it).
   */
  readonly frontendAccountId: string;
  /**
   * Override the ECS cluster name (for testing without AWS lookups).
   * If not provided, the cluster name is resolved from SSM at deploy time.
   */
  readonly clusterNameOverride?: string;
  /**
   * Name (tag:Name) of the upstream VPC hosting the internal ALBs.
   * Default: DevCoreStack/vpc/VPC-Workshop (upstream one-observability-demo).
   */
  readonly upstreamVpcName?: string;
  /**
   * Name of the upstream internal ALB fronting petsearch-java.
   * Default: LB-petsearch-java.
   */
  readonly petSearchAlbName?: string;
  /**
   * Name of the upstream internal ALB fronting petlistadoption-py.
   * Default: LB-petlistadoption-py.
   */
  readonly petListAdoptionAlbName?: string;
  /**
   * Name of the upstream internal ALB fronting petfood-rs.
   * Default: LB-petfood-rs.
   */
  readonly petFoodAlbName?: string;
  /**
   * Name of the upstream internal ALB fronting payforadoption-go.
   * Default: LB-payforadoption-go.
   */
  readonly payForAdoptionAlbName?: string;
}

/**
 * Discovered upstream PetAdoptions resources exposed for downstream constructs.
 */
export interface UpstreamResources {
  /** The ECS cluster name (resolved or overridden). */
  readonly clusterName: string;
  /** The ECS cluster ARN (constructed from account/region/name). */
  readonly clusterArn: string;
  /** SSM parameter references for service URLs (deploy-time tokens). */
  readonly payForAdoptionUrl: string;
  readonly petSearchUrl: string;
  readonly petListAdoptionsUrl: string;
  readonly petStatusUpdaterUrl: string;
}

/**
 * BackendOverlayStack discovers the upstream PetAdoptions resources and
 * exposes them as properties for downstream constructs (alarms, roles,
 * SNS topics, FIS templates, etc.) to consume.
 *
 * Resource discovery uses:
 * - SSM StringParameter.valueForStringParameter for deploy-time values
 * - Constructed ARNs for ECS cluster (avoids VPC lookup at synth)
 * - Props/context for account wiring (OPS account ID from config)
 *
 * This stack does NOT deploy services into the VPC — it only attaches
 * alarms, IAM roles, SNS topics, and FIS templates to existing resources.
 */
export class BackendOverlayStack extends cdk.Stack {
  /** OPS account ID (for cross-account policies). */
  public readonly opsAccountId: string;

  /** Discovered upstream resources. */
  public readonly upstream: UpstreamResources;

  /** The incidents SNS topic (business SLO breaches). */
  public readonly incidentsTopic: sns.Topic;

  /** Read-only IAM role for OPS agents to access BE workload resources. */
  public readonly backendDomainReadRole: iam.Role;

  constructor(scope: Construct, id: string, props: BackendOverlayStackProps) {
    super(scope, id, props);

    this.opsAccountId = props.opsAccountId;

    // --- Resource Discovery via SSM Parameters ---
    // The upstream PetAdoptions deployment publishes key resource names
    // under the /petstore/* SSM namespace. We use deploy-time resolution
    // so that `cdk synth` works without AWS credentials (CI-friendly).

    // The upstream one-observability-demo deployment (pinned ref in
    // config/accounts.json) does NOT publish an ECS cluster name to SSM —
    // there is no /petstore/ecsclustername parameter. The upstream Services
    // stack creates the cluster with the deterministic name
    // "PetsiteECS-cluster", so default to that (overridable for tests).
    // Using a non-existent SSM param here makes the whole stack deploy fail
    // with "Unable to fetch parameters ... from parameter store".
    const clusterName = props.clusterNameOverride ?? 'PetsiteECS-cluster';

    // Upstream publishes the PayForAdoption service endpoint as
    // /petstore/paymentapiurl (NOT /petstore/payforadoptionurl, which does
    // not exist).
    const payForAdoptionUrl = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/paymentapiurl'
    );
    const petSearchUrl = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/searchapiurl'
    );
    const petListAdoptionsUrl = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/petlistadoptionsurl'
    );
    const petStatusUpdaterUrl = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/updateadoptionstatusurl'
    );
    const ddbTableName = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/dynamodbtablename'
    );
    // Upstream publishes the status-update SQS queue URL as
    // /petstore/queueurl (NOT /petstore/sqsqueueurl, which does not exist).
    const sqsQueueUrl = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/queueurl'
    );
    // Derive the queue's PHYSICAL name from the URL for the CloudWatch
    // `QueueName` dimension. The live queue is CloudFormation-generated
    // (e.g. DevCoreStack-QueueResourcessqspetadoption...-<suffix>), NOT the
    // upstream LOGICAL name "petadoptions-statusupdate-queue". An SQS queue
    // URL is https://sqs.<region>.amazonaws.com/<account>/<queue-name>, so
    // the physical name is the 5th (index 4) segment when split on '/'.
    // Deriving it here from the SAME SSM param the chaos tooling uses
    // (/petstore/queueurl) guarantees the lag alarm watches the queue the
    // B2 fault actually targets — a hardcoded literal matched no metric and
    // left the alarm stuck in a non-firing state (fixed 2026-07-29).
    const statusUpdateQueueName = cdk.Fn.select(
      4, cdk.Fn.split('/', sqsQueueUrl));

    // Construct the cluster ARN from account/region/name (no VPC lookup needed)
    const clusterArn = cdk.Arn.format({
      service: 'ecs',
      resource: 'cluster',
      resourceName: clusterName,
    }, this);

    this.upstream = {
      clusterName,
      clusterArn,
      payForAdoptionUrl,
      petSearchUrl,
      petListAdoptionsUrl,
      petStatusUpdaterUrl,
    };

    // ================================================================
    // SSM Exports under /aiops-poc/workload/*
    // Re-export key upstream values under a stable PoC prefix so
    // agents/tools have a known location regardless of upstream naming.
    // ================================================================

    new ssm.StringParameter(this, 'SsmEcsCluster', {
      parameterName: '/aiops-poc/workload/ecs-cluster',
      stringValue: clusterName,
      description: 'ECS cluster name for PetAdoptions services',
    });

    new ssm.StringParameter(this, 'SsmPayForAdoptionUrl', {
      parameterName: '/aiops-poc/workload/pay-for-adoption-url',
      stringValue: payForAdoptionUrl,
      description: 'PayForAdoption service URL',
    });

    new ssm.StringParameter(this, 'SsmPetSearchUrl', {
      parameterName: '/aiops-poc/workload/pet-search-url',
      stringValue: petSearchUrl,
      description: 'PetSearch service URL',
    });

    new ssm.StringParameter(this, 'SsmPetListAdoptionsUrl', {
      parameterName: '/aiops-poc/workload/pet-list-adoptions-url',
      stringValue: petListAdoptionsUrl,
      description: 'PetListAdoptions service URL',
    });

    new ssm.StringParameter(this, 'SsmStatusUpdaterUrl', {
      parameterName: '/aiops-poc/workload/status-updater-url',
      stringValue: petStatusUpdaterUrl,
      description: 'PetStatusUpdater service URL',
    });

    new ssm.StringParameter(this, 'SsmDdbTableName', {
      parameterName: '/aiops-poc/workload/ddb-table-name',
      stringValue: ddbTableName,
      description: 'DynamoDB table name for PetAdoptions',
    });

    new ssm.StringParameter(this, 'SsmSqsQueueUrl', {
      parameterName: '/aiops-poc/workload/sqs-queue-url',
      stringValue: sqsQueueUrl,
      description: 'SQS queue URL for PetAdoptions status updates',
    });

    // ================================================================
    // FE → BE private connectivity via AWS PrivateLink
    //
    // The FE and BE VPCs both use 10.0.0.0/16 (overlapping CIDRs), so
    // VPC peering is impossible. Instead we expose the upstream internal
    // ALBs (petsearch-java, petlistadoption-py, petfood-rs,
    // payforadoption-go) through an internal NLB + VPC Endpoint Service.
    // The FE stack creates an interface endpoint to this service:
    //   endpoint :80   → NLB :80   → petsearch internal ALB :80
    //   endpoint :8080 → NLB :8080 → petlistadoption internal ALB :80
    //   endpoint :8081 → NLB :8081 → petfood internal ALB :80
    //   endpoint :8082 → NLB :8082 → payforadoption internal ALB :80
    // ================================================================

    const upstreamVpcName = props.upstreamVpcName ??
      'DevCoreStack/vpc/VPC-Workshop';

    // The upstream VPC is owned by the upstream PetAdoptions deployment;
    // import it via context lookup (Jest tests synthesize with the CDK
    // dummy lookup VPC, so no override prop is needed).
    const upstreamVpc = ec2.Vpc.fromLookup(this, 'UpstreamVpc', {
      vpcName: upstreamVpcName,
    });

    // The upstream stack does not publish ALB ARNs to SSM (only their DNS
    // names, embedded in the /petstore/* URL parameters), so resolve the
    // ARNs and security groups at deploy time by name via a small
    // DescribeLoadBalancers custom resource — consistent with the overlay's
    // "no synth-time coupling to upstream" style.
    const petSearchAlb = this.lookupUpstreamAlb(
      'PetSearchAlb', props.petSearchAlbName ?? 'LB-petsearch-java');
    const petListAdoptionAlb = this.lookupUpstreamAlb(
      'PetListAdoptionAlb', props.petListAdoptionAlbName ?? 'LB-petlistadoption-py');
    const petFoodAlb = this.lookupUpstreamAlb(
      'PetFoodAlb', props.petFoodAlbName ?? 'LB-petfood-rs');
    // payforadoption-go hosts /api/cleanupadoptions (petsite "Perform
    // Housekeeping"). The upstream ships /petstore/cleanupadoptionsurl
    // pointing at this BE-internal ALB, unreachable from the FE VPC —
    // expose it via the same PrivateLink NLB so the FE-owned parameter
    // can point at the interface endpoint instead (fixes the 504).
    const payForAdoptionAlb = this.lookupUpstreamAlb(
      'PayForAdoptionAlb', props.payForAdoptionAlbName ?? 'LB-payforadoption-go');

    // NLB-forwarded PrivateLink traffic reaches the ALBs from NLB node
    // private IPs inside the upstream VPC, so the (upstream-owned) ALB
    // security groups must allow TCP:80 from the VPC CIDR. Upstream does
    // not have this rule in code — add it against the imported SGs.
    new ec2.CfnSecurityGroupIngress(this, 'PetSearchAlbIngressFromVpc', {
      groupId: petSearchAlb.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 80,
      toPort: 80,
      cidrIp: upstreamVpc.vpcCidrBlock,
      description: 'NLB-forwarded PrivateLink traffic (petsite via FE endpoint)',
    });

    new ec2.CfnSecurityGroupIngress(this, 'PetListAdoptionAlbIngressFromVpc', {
      groupId: petListAdoptionAlb.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 80,
      toPort: 80,
      cidrIp: upstreamVpc.vpcCidrBlock,
      description: 'NLB-forwarded PrivateLink traffic (petsite via FE endpoint)',
    });

    new ec2.CfnSecurityGroupIngress(this, 'PetFoodAlbIngressFromVpc', {
      groupId: petFoodAlb.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 80,
      toPort: 80,
      cidrIp: upstreamVpc.vpcCidrBlock,
      description: 'NLB-forwarded PrivateLink traffic (petsite via FE endpoint)',
    });

    new ec2.CfnSecurityGroupIngress(this, 'PayForAdoptionAlbIngressFromVpc', {
      groupId: payForAdoptionAlb.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 80,
      toPort: 80,
      cidrIp: upstreamVpc.vpcCidrBlock,
      description: 'NLB-forwarded PrivateLink traffic (petsite via FE endpoint)',
    });

    // Internal NLB in the upstream VPC private subnets
    const privatelinkNlb = new elbv2.NetworkLoadBalancer(this, 'PetsitePrivateLinkNlb', {
      vpc: upstreamVpc,
      internetFacing: false,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
    });

    // ALB-type target group: NLB :80 → petsearch internal ALB :80
    const petSearchTargetGroup = new elbv2.NetworkTargetGroup(this, 'PetSearchAlbTargetGroup', {
      vpc: upstreamVpc,
      port: 80,
      protocol: elbv2.Protocol.TCP,
      targets: [new elbv2_targets.AlbArnTarget(petSearchAlb.loadBalancerArn, 80)],
      healthCheck: {
        protocol: elbv2.Protocol.HTTP,
        path: '/',
        // The ALB answering at all is good enough for pass-through routing
        healthyHttpCodes: '200-499',
      },
    });

    privatelinkNlb.addListener('PetSearchListener', {
      port: 80,
      defaultTargetGroups: [petSearchTargetGroup],
    });

    // ALB-type target group: NLB :8080 → petlistadoption internal ALB :80
    const petListAdoptionTargetGroup = new elbv2.NetworkTargetGroup(this, 'PetListAdoptionAlbTargetGroup', {
      vpc: upstreamVpc,
      port: 80,
      protocol: elbv2.Protocol.TCP,
      targets: [new elbv2_targets.AlbArnTarget(petListAdoptionAlb.loadBalancerArn, 80)],
      healthCheck: {
        protocol: elbv2.Protocol.HTTP,
        path: '/',
        healthyHttpCodes: '200-499',
      },
    });

    privatelinkNlb.addListener('PetListAdoptionListener', {
      port: 8080,
      defaultTargetGroups: [petListAdoptionTargetGroup],
    });

    // ALB-type target group: NLB :8081 → petfood internal ALB :80
    const petFoodTargetGroup = new elbv2.NetworkTargetGroup(this, 'PetFoodAlbTargetGroup', {
      vpc: upstreamVpc,
      port: 80,
      protocol: elbv2.Protocol.TCP,
      targets: [new elbv2_targets.AlbArnTarget(petFoodAlb.loadBalancerArn, 80)],
      healthCheck: {
        protocol: elbv2.Protocol.HTTP,
        path: '/',
        healthyHttpCodes: '200-499',
      },
    });

    privatelinkNlb.addListener('PetFoodListener', {
      port: 8081,
      defaultTargetGroups: [petFoodTargetGroup],
    });

    // ALB-type target group: NLB :8082 → payforadoption internal ALB :80
    const payForAdoptionTargetGroup = new elbv2.NetworkTargetGroup(this, 'PayForAdoptionAlbTargetGroup', {
      vpc: upstreamVpc,
      port: 80,
      protocol: elbv2.Protocol.TCP,
      targets: [new elbv2_targets.AlbArnTarget(payForAdoptionAlb.loadBalancerArn, 80)],
      healthCheck: {
        protocol: elbv2.Protocol.HTTP,
        path: '/',
        healthyHttpCodes: '200-499',
      },
    });

    privatelinkNlb.addListener('PayForAdoptionListener', {
      port: 8082,
      defaultTargetGroups: [payForAdoptionTargetGroup],
    });

    // Endpoint service — FE account may connect without manual acceptance
    const privatelinkService = new ec2.VpcEndpointService(this, 'PetsitePrivateLinkService', {
      vpcEndpointServiceLoadBalancers: [privatelinkNlb],
      acceptanceRequired: false,
      allowedPrincipals: [
        new iam.ArnPrincipal(`arn:aws:iam::${props.frontendAccountId}:root`),
      ],
    });

    // Publish the service name for sync-outputs.sh to copy into FE SSM
    new ssm.StringParameter(this, 'SsmPetsitePrivatelinkServiceName', {
      parameterName: '/aiops-poc/workload/petsite-privatelink-service-name',
      stringValue: privatelinkService.vpcEndpointServiceName,
      description: 'PrivateLink endpoint service name for FE petsite → BE APIs',
    });

    new cdk.CfnOutput(this, 'PetsitePrivatelinkServiceNameOutput', {
      value: privatelinkService.vpcEndpointServiceName,
      description: 'PrivateLink endpoint service name (FE consumes via interface endpoint)',
      exportName: 'aiops-poc-petsite-privatelink-service-name',
    });

    // ================================================================
    // Cross-account invoke for the PetFood agent (Waggle chat)
    //
    // The upstream deploys the PetFood agent as a Bedrock AgentCore
    // runtime in THIS account (enabled via ENABLE_PET_FOOD_AGENT in the
    // CodeBuild wrapper) and publishes its ARN to
    // /petstore/petfoodagent-runtime-arn. petsite runs in the FE account
    // and calls bedrock-agentcore:InvokeAgentRuntime on that ARN, so
    // cross-account access requires resource-based policies on BOTH the
    // agent runtime AND its DEFAULT endpoint (AWS evaluates the two
    // hierarchically; if either lacks an explicit allow, the request is
    // denied). The principal is the FE account root — the FE side scopes
    // access down to the petsite task role via its identity policy
    // (FrontendStack), which avoids coupling to the generated role name.
    // ================================================================

    const petfoodAgentRuntimeArn = ssm.StringParameter.valueForStringParameter(
      this, '/petstore/petfoodagent-runtime-arn'
    );

    // The Resource field of an AgentCore resource policy must be the EXACT
    // ARN of the resource the policy is attached to (wildcards rejected).
    const invokeStatement = (resourceArn: string) => JSON.stringify({
      Version: '2012-10-17',
      Statement: [
        {
          Sid: 'AllowFrontendPetsiteInvoke',
          Effect: 'Allow',
          Principal: { AWS: `arn:aws:iam::${props.frontendAccountId}:root` },
          Action: 'bedrock-agentcore:InvokeAgentRuntime',
          Resource: resourceArn,
        },
      ],
    });

    // aws-cdk-lib 2.261.0 has no L1 for AWS::BedrockAgentCore::ResourcePolicy
    // yet — use raw CfnResource (properties: ResourceArn + Policy string).
    new cdk.CfnResource(this, 'PetfoodAgentRuntimePolicy', {
      type: 'AWS::BedrockAgentCore::ResourcePolicy',
      properties: {
        ResourceArn: petfoodAgentRuntimeArn,
        Policy: invokeStatement(petfoodAgentRuntimeArn),
      },
    });

    // Endpoint ARN shape verified against the live control plane:
    //   <runtime-arn>/runtime-endpoint/DEFAULT
    const petfoodAgentEndpointArn =
      `${petfoodAgentRuntimeArn}/runtime-endpoint/DEFAULT`;

    new cdk.CfnResource(this, 'PetfoodAgentEndpointPolicy', {
      type: 'AWS::BedrockAgentCore::ResourcePolicy',
      properties: {
        ResourceArn: petfoodAgentEndpointArn,
        Policy: invokeStatement(petfoodAgentEndpointArn),
      },
    });

    // ================================================================
    // FIS Experiment Templates (payments-crash, search-crash)
    // ================================================================

    // Shared FIS execution role with permission to stop ECS tasks
    const fisRole = new iam.Role(this, 'FisExecutionRole', {
      assumedBy: new iam.ServicePrincipal('fis.amazonaws.com'),
      description: 'Allows FIS to stop ECS tasks for chaos experiments',
    });

    fisRole.addToPolicy(new iam.PolicyStatement({
      sid: 'FisEcsStopTask',
      effect: iam.Effect.ALLOW,
      actions: [
        'ecs:StopTask',
        'ecs:ListTasks',
        'ecs:DescribeTasks',
      ],
      resources: ['*'],
      conditions: {
        ArnEquals: {
          'ecs:cluster': clusterArn,
        },
      },
    }));

    fisRole.addToPolicy(new iam.PolicyStatement({
      sid: 'FisEcsDescribe',
      effect: iam.Effect.ALLOW,
      actions: [
        'ecs:DescribeServices',
        'ecs:DescribeClusters',
      ],
      resources: ['*'],
    }));

    // The upstream does not publish ECS service names to SSM (only URLs),
    // so the FIS targets use the deterministic upstream service names,
    // verified against the live deployment (us-east-1):
    //   aws ecs list-services --cluster PetsiteECS-cluster
    //     → payforadoption-go, petsearch-java, petlistadoption-py, petfood-rs
    // See docs/scenarios.md "Resource references (verified live)". The old
    // names PayForAdoption / PetSearch do not exist — targeting them made
    // the aws:ecs:task selector match zero tasks (silent no-op).

    // payments-crash: Stop ECS tasks for the payforadoption-go service
    new fis.CfnExperimentTemplate(this, 'FisPaymentsCrash', {
      description: 'Stop payforadoption-go ECS tasks to simulate payments crash',
      roleArn: fisRole.roleArn,
      stopConditions: [{ source: 'none' }],
      tags: { Name: 'payments-crash' },
      targets: {
        'payment-tasks': {
          resourceType: 'aws:ecs:task',
          selectionMode: 'ALL',
          parameters: {
            cluster: clusterName,
            service: 'payforadoption-go',
          },
        },
      },
      actions: {
        'stop-payment-tasks': {
          actionId: 'aws:ecs:stop-task',
          parameters: {},
          targets: { Tasks: 'payment-tasks' },
        },
      },
    });

    // search-crash: Stop ECS tasks for the petsearch-java service
    new fis.CfnExperimentTemplate(this, 'FisSearchCrash', {
      description: 'Stop petsearch-java ECS tasks to simulate search crash',
      roleArn: fisRole.roleArn,
      stopConditions: [{ source: 'none' }],
      tags: { Name: 'search-crash' },
      targets: {
        'search-tasks': {
          resourceType: 'aws:ecs:task',
          selectionMode: 'ALL',
          parameters: {
            cluster: clusterName,
            service: 'petsearch-java',
          },
        },
      },
      actions: {
        'stop-search-tasks': {
          actionId: 'aws:ecs:stop-task',
          parameters: {},
          targets: { Tasks: 'search-tasks' },
        },
      },
    });

    // ================================================================
    // Incidents SNS topic with cross-account topic policy
    // ================================================================

    this.incidentsTopic = new sns.Topic(this, 'IncidentsTopic', {
      topicName: 'aiops-poc-incidents',
      displayName: 'AIOps PoC Backend Incidents',
    });

    // Allow the OPS account to subscribe and receive messages
    this.incidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowOpsAccountSubscribe',
      effect: iam.Effect.ALLOW,
      principals: [new iam.AccountPrincipal(this.opsAccountId)],
      actions: ['sns:Subscribe', 'sns:Receive'],
      resources: [this.incidentsTopic.topicArn],
    }));

    // CloudWatch alarm actions (same-account) need sns:Publish — the
    // cross-account subscribe policy replaced the default and dropped it
    // (fixed 2026-07-27). Scope the grant to the CloudWatch service
    // principal in THIS account (the topic's own account) via aws:SourceAccount.
    this.incidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowCloudWatchAlarmPublish',
      effect: iam.Effect.ALLOW,
      principals: [new iam.ServicePrincipal('cloudwatch.amazonaws.com')],
      actions: ['sns:Publish'],
      resources: [this.incidentsTopic.topicArn],
      conditions: {
        StringEquals: { 'aws:SourceAccount': this.account },
      },
    }));

    // Restore the account-owner publish/management grant that the custom
    // policy above dropped when it replaced the SNS default (fixed 2026-07-27).
    this.incidentsTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: 'AllowOwnerPublish',
      effect: iam.Effect.ALLOW,
      principals: [new iam.AccountPrincipal(this.account)],
      actions: ['sns:Publish'],
      resources: [this.incidentsTopic.topicArn],
    }));

    // ================================================================
    // BE per-service SLO alarms — tier 2 of a three-tier alarm design
    // ================================================================
    // The PoC splits alarms into three tiers, and the alarm NAME encodes
    // which tier a signal came from, so an investigation title alone
    // ("<name> is in ALARM") already tells an operator where the signal
    // originated:
    //
    //   aiops-poc-fe-golden-*  customer-facing golden signals (FE account)
    //   aiops-poc-be-slo-*     per-service business SLO breaches (here)
    //   aiops-poc-be-infra-*   raw infrastructure "why" signals (below)
    //
    // TIER 1 — `aiops-poc-fe-golden-*` (FE account) is what PAGES the
    // app-team first responder: the shopper-journey canary and the petsite
    // ALB error rate. A golden signal is what the customer actually feels,
    // and it fires faster than infra metrics, so it is the right thing to
    // wake someone for and the right thing to frame an incident around.
    //
    // TIER 2 — the `aiops-poc-be-slo-*` alarms below are per-service SLO
    // breaches used as EVIDENCE during an investigation, not as pagers.
    // Five of them (checkout latency, payments error rate, payments
    // availability, search latency, search error rate) deliberately have NO
    // addAlarmAction(): the FE golden signal is the sole trigger, so the
    // investigation is framed customer-first. This is a measured decision,
    // not a preference — on the 2026-07-28 payments-crash validation run the
    // BE `adoption-error-rate` alarm fired 13 minutes BEFORE the FE journey
    // alarm and hijacked the incident framing: the primary investigation was
    // opened by a backend infrastructure symptom and the customer-impact
    // alarm was de-duplicated into it as a footnote.
    //
    // EXCEPTION — `aiops-poc-be-slo-statusupdate-lag` still pages. Scenario
    // B2 is asynchronous (payforadoption → SQS → petstatusupdater): checkout
    // stays fast and the FE canary journey passes, so no FE golden signal can
    // ever observe it. Leaving it silent would make B2 undetectable. It is
    // still a BUSINESS SLO (customer-visible staleness of pet status), not an
    // infra metric, so the "only golden/business signals page" invariant
    // holds.
    //
    // TIER 3 — `aiops-poc-be-infra-*` (further below) are the slow "why"
    // signals (CPU, memory, running task count). They never page.

    // --- Application Signals metric identity (verified live 2026-07-27) ---
    // CloudWatch keys ApplicationSignals metrics on the FULL dimension set
    // [Environment, Service]; an alarm that omits Environment (or uses the
    // wrong Service name) matches NO metric and sits in INSUFFICIENT_DATA
    // forever. The emitted Service name is NOT the ECS service name — it is
    // the value of the OTEL/App Signals service name env var on the task
    // definition (e.g. PAYFORADOPTION_SERVICE_NAME), which upstream sets to
    // the "<svc>-api-<lang>" form. Verified against live ListMetrics:
    //   payforadoption: Environment=generic:default,
    //                   Service=payforadoption-api-go
    //   petsearch:      Environment=ecs:PetsiteECS-cluster,
    //                   Service=petsearch-api-java
    // (The ECS service names payforadoption-go / petsearch-java are still
    // correct for FIS targeting — they just are not the App Signals keys.)
    const payForAdoptionSignalsDimensions = {
      Environment: 'generic:default',
      Service: 'payforadoption-api-go',
    };
    const petSearchSignalsDimensions = {
      Environment: 'ecs:PetsiteECS-cluster',
      Service: 'petsearch-api-java',
    };

    // --- Checkout latency: p99 > 2s for 3x60s (evidence only, no action) ---
    new cloudwatch.Alarm(this, 'CheckoutLatencyAlarm', {
      alarmName: 'aiops-poc-be-slo-checkout-latency-p99',
      alarmDescription: 'Adoption checkout latency p99 > 2s (payforadoption-go)',
      metric: new cloudwatch.Metric({
        namespace: 'ApplicationSignals',
        metricName: 'Latency',
        dimensionsMap: payForAdoptionSignalsDimensions,
        statistic: 'p99',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 2000, // milliseconds
      evaluationPeriods: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // --- Payments error rate + availability, measured at the ALB hop ---
    // A crashed service publishes NOTHING: no App Signals faults, no traces.
    // An error-rate alarm on payforadoption's own emitted metrics therefore
    // can never fire on the payments-crash (B3) scenario. What a payments
    // crash actually produces is 503s at the caller hop — the internal ALB
    // in front of payforadoption-go — so measure there instead, and pair it
    // with a HealthyHostCount availability alarm that does not depend on
    // traffic at all.
    //
    // NOTE: these two are EVIDENCE, not the payments-crash trigger. The
    // trigger is the FE golden signal (aiops-poc-fe-golden-journey-success /
    // -checkout-error-rate), which is what the customer feels. Both alarms
    // below are deliberately actionless so they cannot open (or reframe) the
    // incident ahead of the customer-facing signal.
    const payForAdoptionAlbDimension = this.albMetricDimension(
      payForAdoptionAlb.loadBalancerArn);
    const payForAdoptionTgDimension = this.lookupUpstreamTargetGroupDimension(
      'PayForAdoptionTg', payForAdoptionAlb.loadBalancerArn);
    const payForAdoptionAlbDimensions = {
      LoadBalancer: payForAdoptionAlbDimension,
    };

    new cloudwatch.Alarm(this, 'AdoptionErrorRateAlarm', {
      alarmName: 'aiops-poc-be-slo-payments-error-rate',
      alarmDescription:
        'Adoption error rate > 2% (503s at LB-payforadoption-go — payments unavailable)',
      metric: new cloudwatch.MathExpression({
        expression: '(elb5xx / requests) * 100',
        usingMetrics: {
          elb5xx: new cloudwatch.Metric({
            namespace: 'AWS/ApplicationELB',
            metricName: 'HTTPCode_ELB_5XX_Count',
            dimensionsMap: payForAdoptionAlbDimensions,
            statistic: 'Sum',
            period: cdk.Duration.seconds(60),
          }),
          requests: new cloudwatch.Metric({
            namespace: 'AWS/ApplicationELB',
            metricName: 'RequestCount',
            dimensionsMap: payForAdoptionAlbDimensions,
            statistic: 'Sum',
            period: cdk.Duration.seconds(60),
          }),
        },
        period: cdk.Duration.seconds(60),
      }),
      threshold: 2,
      evaluationPeriods: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      // Missing data here means no traffic at all, which is genuinely not a
      // breach of an error *rate* — the availability alarm below covers the
      // no-traffic case.
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    new cloudwatch.Alarm(this, 'AdoptionAvailabilityAlarm', {
      alarmName: 'aiops-poc-be-slo-payments-availability',
      alarmDescription:
        'No healthy payforadoption targets behind LB-payforadoption-go (payments down)',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'HealthyHostCount',
        dimensionsMap: {
          TargetGroup: payForAdoptionTgDimension,
          LoadBalancer: payForAdoptionAlbDimension,
        },
        statistic: 'Minimum',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 1,
      evaluationPeriods: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
      // When the target group drains completely the ALB can stop publishing
      // HealthyHostCount altogether — that silence IS the event, so missing
      // data must breach (not be treated as healthy).
      treatMissingData: cloudwatch.TreatMissingData.BREACHING,
    });

    // --- Search latency: p99 > 4s on GET /api/search for 2x300s ---
    //
    // Retuned 2026-07-28 from "p95 > 1s for 3x60s" after a read-only
    // investigation of why the alarm flapped continuously. Measured facts:
    //
    //   * Traffic mixing: the service-wide dimension set aggregates three
    //     operations, and only ~36% of samples are real searches — the rest
    //     are `GET /health/status` and `GET /**`. A percentile over that mix
    //     is not a search SLI.
    //   * Sampling noise: 60s buckets hold only ~31 samples, so p95 swung by
    //     ~300x between adjacent minutes. Any threshold in that regime is a
    //     coin flip.
    //   * KNOWN, STABLE tail: ~12% of `GET /api/search` calls take ~3.0s and
    //     have for 11 straight days (daily p99 3049–3170 ms, flat). Downstream
    //     (DynamoDB) calls are only ~45ms and task CPU is 0.25%, so this is an
    //     in-app upstream delay, not a resource problem we can tune away.
    //     Corroborated at the ALB hop (TargetResponseTime p95 2.89s).
    //
    // So the threshold is derived from measured behaviour rather than a round
    // number: 4000 ms sits above the ~3.0–3.2s steady-state floor with margin,
    // p99 over a 300s period gives ~150+ samples per datapoint (noise damped),
    // and the Operation dimension scopes the alarm to the operation we care
    // about. Net effect: quiet in steady state, fires on a NEW regression.
    //
    // NOTE: the Operation dimension is added HERE only — the shared
    // petSearchSignalsDimensions constant stays service-wide so the search
    // ERROR-RATE alarm keeps catching faults on any operation.
    new cloudwatch.Alarm(this, 'SearchLatencyAlarm', {
      alarmName: 'aiops-poc-be-slo-search-latency-p99',
      alarmDescription:
        'Search latency p99 > 4s on GET /api/search (regression detector above the known ~3s upstream floor)',
      metric: new cloudwatch.Metric({
        namespace: 'ApplicationSignals',
        metricName: 'Latency',
        dimensionsMap: {
          ...petSearchSignalsDimensions,
          // Verified live: ApplicationSignals publishes the 3-dimension set
          // [Environment, Service, Operation] for this operation.
          Operation: 'GET /api/search',
        },
        statistic: 'p99',
        period: cdk.Duration.seconds(300),
      }),
      threshold: 4000, // milliseconds
      evaluationPeriods: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // --- Search error rate: > 2% for 3x60s ---
    new cloudwatch.Alarm(this, 'SearchErrorRateAlarm', {
      alarmName: 'aiops-poc-be-slo-search-error-rate',
      alarmDescription: 'Search error rate > 2% (petsearch-java)',
      metric: new cloudwatch.MathExpression({
        expression: '(faults / samples) * 100',
        usingMetrics: {
          faults: new cloudwatch.Metric({
            namespace: 'ApplicationSignals',
            metricName: 'Fault',
            dimensionsMap: petSearchSignalsDimensions,
            statistic: 'Sum',
            period: cdk.Duration.seconds(60),
          }),
          samples: new cloudwatch.Metric({
            namespace: 'ApplicationSignals',
            metricName: 'Fault',
            dimensionsMap: petSearchSignalsDimensions,
            statistic: 'SampleCount',
            period: cdk.Duration.seconds(60),
          }),
        },
        period: cdk.Duration.seconds(60),
      }),
      threshold: 2,
      evaluationPeriods: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // --- Pet-status update lag: SQS oldest message age > 300s ---
    // The ONE BE SLO alarm that still pages: B2 is asynchronous, so checkout
    // stays fast, the FE canary journey passes, and no FE golden signal can
    // observe it. See the tier notes at the top of this section.
    const statusUpdateLagAlarm = new cloudwatch.Alarm(this, 'StatusUpdateLagAlarm', {
      alarmName: 'aiops-poc-be-slo-statusupdate-lag',
      alarmDescription: 'Pet-status update lag > 300s (SQS queue age)',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/SQS',
        metricName: 'ApproximateAgeOfOldestMessage',
        dimensionsMap: { QueueName: statusUpdateQueueName },
        statistic: 'Maximum',
        period: cdk.Duration.seconds(60),
      }),
      threshold: 300, // seconds
      evaluationPeriods: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    statusUpdateLagAlarm.addAlarmAction(new cw_actions.SnsAction(this.incidentsTopic));

    // ================================================================
    // BE INFRASTRUCTURE alarms — evidence only, with ONE deliberate exception
    // ================================================================
    // Design intent (golden-signal vs infra demo): the customer-facing
    // golden-signal SLO alarms live in the FE account and page the app-team
    // first responder. The alarms below are the slower "why" signals — CPU,
    // memory, task count on the BE ECS services. They exist so the platform
    // agent finds corroborating evidence while investigating an incident.
    //
    // GOVERNING PRINCIPLE: no infra alarm pages the customer-facing app-team
    // space. Almost all of these infra alarms are therefore pure evidence and
    // have NO addAlarmAction() — nothing is published anywhere, so they never
    // wake anyone up.
    //
    // THE ONE EXCEPTION — `aiops-poc-be-infra-payments-tasks`. This single
    // infra alarm DOES page: it publishes to the BE incidents topic
    // (aiops-poc-incidents), and the OPS webhook bridge routes every
    // `aiops-poc-be-infra-*` alarm to the PLATFORM DevOps Agent space (the
    // infra-owning space that holds live BE telemetry), NOT the customer-
    // facing app-team space. So the app-team space still never sees a raw
    // infra page; the platform space gets this one so it can run its own live
    // RCA in parallel with the app-team's customer-first investigation. All
    // OTHER infra alarms (both cpu/memory alarms and the search tasks alarm)
    // remain actionless evidence.
    for (const svc of ['payforadoption-go', 'petsearch-java'] as const) {
      // Short id/name segment: payments for the checkout path, search for the
      // pet-search path — matches the scenario naming in docs/scenarios.md.
      const key = svc === 'payforadoption-go' ? 'payments' : 'search';
      const idKey = svc === 'payforadoption-go' ? 'Payments' : 'Search';
      const ecsDimensions = {
        ClusterName: clusterName,
        ServiceName: svc,
      };

      new cloudwatch.Alarm(this, `Infra${idKey}CpuAlarm`, {
        alarmName: `aiops-poc-be-infra-${key}-cpu`,
        alarmDescription:
          `ECS CPUUtilization > 80% on ${svc} — infra evidence (does not page)`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/ECS',
          metricName: 'CPUUtilization',
          dimensionsMap: ecsDimensions,
          statistic: 'Average',
          period: cdk.Duration.seconds(60),
        }),
        threshold: 80,
        evaluationPeriods: 3,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });

      new cloudwatch.Alarm(this, `Infra${idKey}MemoryAlarm`, {
        alarmName: `aiops-poc-be-infra-${key}-memory`,
        alarmDescription:
          `ECS MemoryUtilization > 80% on ${svc} — infra evidence (does not page)`,
        metric: new cloudwatch.Metric({
          namespace: 'AWS/ECS',
          metricName: 'MemoryUtilization',
          dimensionsMap: ecsDimensions,
          statistic: 'Average',
          period: cdk.Duration.seconds(60),
        }),
        threshold: 80,
        evaluationPeriods: 3,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      });

      // Container Insights is enabled on the cluster (containerInsights =
      // enhanced) and ECS/ContainerInsights RunningTaskCount is published for
      // both services — verified live via ListMetrics on the
      // [ClusterName, ServiceName] dimension set.
      // The payments tasks alarm is the ONE infra alarm that pages (see the
      // governing-principle note above): it publishes to the BE incidents
      // topic, which the OPS webhook bridge routes to the PLATFORM space by
      // the aiops-poc-be-infra-* prefix. The search tasks alarm and both
      // cpu/memory alarms stay actionless evidence.
      const tasksAlarm = new cloudwatch.Alarm(this, `Infra${idKey}TasksAlarm`, {
        alarmName: `aiops-poc-be-infra-${key}-tasks`,
        alarmDescription:
          key === 'payments'
            ? `ECS RunningTaskCount < 1 on ${svc} — pages the PLATFORM space via bridge routing (aiops-poc-be-infra-* prefix)`
            : `ECS RunningTaskCount < 1 on ${svc} — infra evidence (does not page)`,
        metric: new cloudwatch.Metric({
          namespace: 'ECS/ContainerInsights',
          metricName: 'RunningTaskCount',
          dimensionsMap: ecsDimensions,
          statistic: 'Minimum',
          period: cdk.Duration.seconds(60),
        }),
        threshold: 1,
        evaluationPeriods: 2,
        comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
        // A fully-stopped service stops publishing altogether; that silence
        // IS the event, so missing data must breach.
        treatMissingData: cloudwatch.TreatMissingData.BREACHING,
      });
      if (key === 'payments') {
        tasksAlarm.addAlarmAction(new cw_actions.SnsAction(this.incidentsTopic));
      }
    }

    // ================================================================
    // Scale upstream petsite to zero — OMITTED for this upstream topology
    // ================================================================
    // NOTE: The original design assumed petsite ran as an ECS service named
    // "petsite" on the upstream ECS cluster and used an L1 CfnService to set
    // desiredCount=0. That approach does not work here for two reasons:
    //   1. AWS::ECS::Service (CfnService) always *creates* a new service and
    //      requires a TaskDefinition — it cannot scale an existing/external
    //      service. Deploying it fails with "TaskDefinition can not be blank".
    //   2. In this deployed upstream (one-observability-demo), petsite runs on
    //      the EKS cluster (PetsiteEKS-cluster), not as an ECS service on
    //      PetsiteECS-cluster (which hosts payforadoption-go, petsearch-java,
    //      petlistadoption-py, petfood-rs). There is no ECS "petsite" service
    //      to scale to zero.
    // Disabling the upstream petsite (an EKS Deployment) is out of scope for
    // this CDK stack and would require kubectl/EKS access. The construct is
    // intentionally omitted so the rest of the overlay (alarms, SNS, read
    // role, FIS templates, SSM exports) can deploy.

    // ================================================================
    // aiops-backend-domain-read role (cross-account read-only for OPS agents)
    // ================================================================
    // Trust is scoped to the specific OPS task role ARNs (agent + MCP),
    // not the entire OPS account root.
    const opsAgentTaskRoleArn = `arn:aws:iam::${props.opsAccountId}:role/aiops-poc-agent-task-role`;
    const opsMcpTaskRoleArn = `arn:aws:iam::${props.opsAccountId}:role/aiops-poc-mcp-task-role`;

    // Trust the OPS account, scoped to the specific agent/MCP task role ARNs via
    // an aws:PrincipalArn condition. Using ArnPrincipal(<role arn>) directly
    // requires those roles to already exist — IAM rejects non-existent role
    // principals with "Invalid principal in policy". Those task roles are
    // created later in the OPS agents/infra stack (step 4), which runs after
    // this backend overlay (step 2). The account-root principal + PrincipalArn
    // condition keeps the trust scoped to exactly those two roles while removing
    // the cross-account ordering dependency.
    this.backendDomainReadRole = new iam.Role(this, 'BackendDomainReadRole', {
      roleName: 'aiops-backend-domain-read',
      assumedBy: new iam.PrincipalWithConditions(
        new iam.AccountPrincipal(props.opsAccountId),
        {
          ArnEquals: {
            'aws:PrincipalArn': [opsAgentTaskRoleArn, opsMcpTaskRoleArn],
          },
        },
      ),
      description: 'Read-only role for OPS fallback agents and diagnostics MCP to access BE workload resources',
    });

    // Inline policy: read-only actions across relevant services
    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'CloudWatchReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'cloudwatch:GetMetricStatistics',
        'cloudwatch:GetMetricData',
        'cloudwatch:DescribeAlarms',
        'cloudwatch:ListMetrics',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'EcsReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'ecs:DescribeServices',
        'ecs:DescribeTasks',
        'ecs:ListTasks',
        'ecs:DescribeClusters',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'DynamoDBReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'dynamodb:DescribeTable',
        'dynamodb:GetItem',
        'dynamodb:Query',
        'dynamodb:Scan',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'SqsReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'sqs:GetQueueAttributes',
        'sqs:GetQueueUrl',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'RdsReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'rds:DescribeDBInstances',
        'rds:DescribeDBClusters',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'LambdaReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'lambda:GetFunctionConfiguration',
        'lambda:ListEventSourceMappings',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'SyntheticsReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'synthetics:GetCanaryRuns',
        'synthetics:DescribeCanaries',
      ],
      resources: ['*'],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'SsmReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'ssm:GetParameter',
        'ssm:GetParametersByPath',
      ],
      resources: [
        `arn:aws:ssm:${this.region}:${this.account}:parameter/petstore/*`,
      ],
    }));

    this.backendDomainReadRole.addToPolicy(new iam.PolicyStatement({
      sid: 'LogsReadOnly',
      effect: iam.Effect.ALLOW,
      actions: [
        'logs:GetLogEvents',
        'logs:FilterLogEvents',
        'logs:DescribeLogGroups',
      ],
      resources: ['*'],
    }));

    // --- Stack outputs for downstream consumers and debugging ---
    new cdk.CfnOutput(this, 'EcsClusterName', {
      value: clusterName,
      description: 'Upstream PetAdoptions ECS cluster name',
      exportName: 'aiops-poc-ecs-cluster-name',
    });

    new cdk.CfnOutput(this, 'EcsClusterArn', {
      value: clusterArn,
      description: 'Upstream PetAdoptions ECS cluster ARN',
      exportName: 'aiops-poc-ecs-cluster-arn',
    });

    new cdk.CfnOutput(this, 'OpsAccountId', {
      value: this.opsAccountId,
      description: 'OPS account ID for cross-account policies',
      exportName: 'aiops-poc-ops-account-id',
    });

    new cdk.CfnOutput(this, 'IncidentsTopicArn', {
      value: this.incidentsTopic.topicArn,
      description: 'Backend incidents SNS topic ARN',
      exportName: 'aiops-poc-be-incidents-topic-arn',
    });

    new cdk.CfnOutput(this, 'BackendDomainReadRoleArn', {
      value: this.backendDomainReadRole.roleArn,
      description: 'ARN of the read-only role for OPS agents to access BE',
      exportName: 'aiops-poc-backend-domain-read-role-arn',
    });
  }

  /**
   * Resolve an upstream internal ALB's ARN and security group at deploy
   * time by load balancer name (DescribeLoadBalancers custom resource).
   *
   * The upstream deployment does not export ALB ARNs (only DNS names via
   * /petstore/* URLs), and `ApplicationLoadBalancer.fromLookup` needs an
   * ARN or tags — so a small SDK-call custom resource is the least
   * intrusive way to keep the overlay decoupled from upstream at synth.
   */
  private lookupUpstreamAlb(
    id: string,
    albName: string,
  ): { loadBalancerArn: string; securityGroupId: string } {
    const lookup = new cr.AwsCustomResource(this, `${id}Lookup`, {
      // Use the AWS SDK bundled in the Lambda runtime. The service must be
      // given in SDK v3 naming ('elastic-load-balancing-v2') — the legacy
      // 'ElasticLoadBalancingV2' name maps to the nonexistent package
      // @aws-sdk/client-elasticloadbalancingv2 and the handler fails with
      // "Package ... does not exist".
      installLatestAwsSdk: false,
      onUpdate: {
        service: 'elastic-load-balancing-v2',
        action: 'DescribeLoadBalancers',
        parameters: { Names: [albName] },
        physicalResourceId: cr.PhysicalResourceId.of(`alb-lookup-${albName}`),
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          actions: ['elasticloadbalancing:DescribeLoadBalancers'],
          resources: ['*'],
        }),
      ]),
      resourceType: 'Custom::UpstreamAlbLookup',
    });

    return {
      loadBalancerArn: lookup.getResponseField('LoadBalancers.0.LoadBalancerArn'),
      securityGroupId: lookup.getResponseField('LoadBalancers.0.SecurityGroups.0'),
    };
  }

  /**
   * Derive the CloudWatch `LoadBalancer` dimension value from an ALB ARN.
   *
   * The dimension is the ARN *suffix*, i.e. `app/<name>/<id>`, whereas the
   * ARN resource part is `loadbalancer/app/<name>/<id>`. Splitting the ARN
   * on the literal `loadbalancer/` and taking the second element yields the
   * suffix without hardcoding the (CDK/upstream-generated) id.
   */
  private albMetricDimension(loadBalancerArn: string): string {
    return cdk.Fn.select(1, cdk.Fn.split('loadbalancer/', loadBalancerArn));
  }

  /**
   * Resolve the CloudWatch `TargetGroup` dimension value for an ALB's
   * (single) target group at deploy time.
   *
   * The upstream does not export target group ARNs, so mirror
   * lookupUpstreamAlb's AwsCustomResource pattern with DescribeTargetGroups
   * filtered by LoadBalancerArn. The dimension value is the ARN suffix
   * `targetgroup/<name>/<id>`, which is the 6th (index 5) colon-separated
   * ARN field.
   */
  private lookupUpstreamTargetGroupDimension(
    id: string,
    loadBalancerArn: string,
  ): string {
    const lookup = new cr.AwsCustomResource(this, `${id}TargetGroupLookup`, {
      installLatestAwsSdk: false,
      onUpdate: {
        service: 'elastic-load-balancing-v2',
        action: 'DescribeTargetGroups',
        parameters: { LoadBalancerArn: loadBalancerArn },
        physicalResourceId: cr.PhysicalResourceId.of(`tg-lookup-${id}`),
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([
        new iam.PolicyStatement({
          actions: ['elasticloadbalancing:DescribeTargetGroups'],
          resources: ['*'],
        }),
      ]),
      resourceType: 'Custom::UpstreamTargetGroupLookup',
    });

    const targetGroupArn = lookup.getResponseField('TargetGroups.0.TargetGroupArn');
    return cdk.Fn.select(5, cdk.Fn.split(':', targetGroupArn));
  }
}
