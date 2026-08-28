#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { BackendOverlayStack } from '../lib/backend-overlay-stack';
import { BackendAgentRoleStack } from '../lib/backend-agent-role-stack';
// Cdk_Config_Loader — the only reader of config/accounts.json.
import { loadAccounts } from '../../../../config/accounts-config';

const app = new cdk.App();

// Pin the bootstrap qualifier explicitly (aws-cdk-lib 2.x DefaultStackSynthesizer).
// Left implicit, the synthesizer reads `@aws-cdk/core:bootstrapQualifier` from
// whatever cdk.json context is in scope, so synthesizing from a directory that
// declares another qualifier would silently retarget this stack's staging roles
// and its /cdk-bootstrap/<qualifier>/version check. Upstream PetAdoptions, which
// this overlay sits on top of in the same account, declares one — so that is a
// real hazard here rather than a theoretical one. DEFAULT_QUALIFIER is the value
// the synthesizer already falls back to, so this changes no synthesized output —
// it only removes the ambient input.
const synthesizer = () =>
  new cdk.DefaultStackSynthesizer({
    qualifier: cdk.DefaultStackSynthesizer.DEFAULT_QUALIFIER,
  });

// Precedence: cdk context (-c backend.region=…) > AIOPS_* env >
// config/accounts.json > the default declared in config/accounts.json.template.
const accounts = loadAccounts({ context: (k) => app.node.tryGetContext(k) });

new BackendOverlayStack(app, 'BackendOverlayStack', {
  synthesizer: synthesizer(),
  env: {
    account: accounts.backend.accountId,
    region: accounts.backend.region,
  },
  opsAccountId: accounts.ops.accountId,
  frontendAccountId: accounts.frontend.accountId,
  description: 'PoC overlay on upstream PetAdoptions: SLO alarms, SNS topic, read role, SSM exports, FIS templates, PrivateLink endpoint service',
});

// Separate stack — deployed AFTER Agent Spaces exist and sync-outputs writes
// the platform space ARN to SSM at /aiops-poc/agent-spaces/platform/arn
new BackendAgentRoleStack(app, 'BackendAgentRoleStack', {
  synthesizer: synthesizer(),
  env: {
    account: accounts.backend.accountId,
    region: accounts.backend.region,
  },
  description: 'DevOps Agent monitor role for the platform space (deployed after Agent Spaces)',
});
