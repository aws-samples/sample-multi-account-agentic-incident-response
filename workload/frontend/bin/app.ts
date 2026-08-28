#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { FrontendStack } from '../lib/frontend-stack';
import { FrontendAgentRoleStack } from '../lib/frontend-agent-role-stack';
// Cdk_Config_Loader — the only reader of config/accounts.json.
import { loadAccounts } from '../../../config/accounts-config';

const app = new cdk.App();

// Pin the bootstrap qualifier explicitly (aws-cdk-lib 2.x DefaultStackSynthesizer).
// Left implicit, the synthesizer reads `@aws-cdk/core:bootstrapQualifier` from
// whatever cdk.json context is in scope, so synthesizing from a directory that
// declares another qualifier would silently retarget this stack's staging roles
// and its /cdk-bootstrap/<qualifier>/version check. Upstream PetAdoptions declares
// one, so that is a real hazard in this repo rather than a theoretical one.
// DEFAULT_QUALIFIER is the value the synthesizer already falls back to, so this
// changes no synthesized output — it only removes the ambient input.
const synthesizer = () =>
  new cdk.DefaultStackSynthesizer({
    qualifier: cdk.DefaultStackSynthesizer.DEFAULT_QUALIFIER,
  });

// Precedence: cdk context (-c frontend.region=…) > AIOPS_* env >
// config/accounts.json > the default declared in config/accounts.json.template.
const accounts = loadAccounts({ context: (k) => app.node.tryGetContext(k) });

// Petsite autoscaling max capacity.
// The FrontendStack both creates and (previously) looked up the SSM parameter
// `/aiops-poc/workload/petsite-max-capacity`, which is circular on first deploy
// (a synth-time valueFromLookup fails because the parameter does not exist yet).
// We pass an explicit override instead; the stack still creates/seeds the SSM
// parameter for chaos tooling (ui-no-scale). Override via `-c petsiteMaxCapacity=N`.
const petsiteMaxCapacityCtx = app.node.tryGetContext('petsiteMaxCapacity');
const petsiteMaxCapacity = petsiteMaxCapacityCtx ? Number(petsiteMaxCapacityCtx) : 4;

new FrontendStack(app, 'FrontendStack', {
  synthesizer: synthesizer(),
  env: {
    account: accounts.frontend.accountId,
    region: accounts.frontend.region,
  },
  opsAccountId: accounts.ops.accountId,
  backendAccountId: accounts.backend.accountId,
  upstreamOrg: accounts.upstream.org,
  upstreamRepo: accounts.upstream.repo,
  upstreamRef: accounts.upstream.ref,
  maxCapacityOverride: petsiteMaxCapacity,
  description: 'Petsite from unmodified upstream source: ECS + ALB + SSM-driven autoscaling (Account FE)',
});

// Separate stack: deployed AFTER Agent Spaces exist and space ARNs are
// synced to FE SSM via sync-outputs.sh (deploy order step 7).
new FrontendAgentRoleStack(app, 'FrontendAgentRoleStack', {
  synthesizer: synthesizer(),
  env: {
    account: accounts.frontend.accountId,
    region: accounts.frontend.region,
  },
  description: 'DevOps Agent monitor role for app-team space (deployed after Agent Spaces exist)',
});
