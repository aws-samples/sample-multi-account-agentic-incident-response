#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AgentsInfraStack } from '../lib/agents-infra-stack';
// Cdk_Config_Loader — the only reader of config/accounts.json. CommonJS with a
// hand-written .d.ts because a .ts file at config/ is outside this app's
// rootDir (see config/accounts-config.d.ts).
import { loadAccounts } from '../../../config/accounts-config';

const app = new cdk.App();

// Pin the bootstrap qualifier explicitly (aws-cdk-lib 2.x DefaultStackSynthesizer).
// Left implicit, the synthesizer reads `@aws-cdk/core:bootstrapQualifier` from
// whatever cdk.json context is in scope, so synthesizing from a directory that
// declares another qualifier would silently retarget this stack's staging roles
// and its /cdk-bootstrap/<qualifier>/version check. Upstream PetAdoptions does
// declare one, so that is a real hazard in this repo rather than a theoretical
// one. DEFAULT_QUALIFIER is the value the synthesizer already falls back to, so
// this changes no synthesized output — it only removes the ambient input.
const synthesizer = () =>
  new cdk.DefaultStackSynthesizer({
    qualifier: cdk.DefaultStackSynthesizer.DEFAULT_QUALIFIER,
  });

// Precedence: cdk context (-c backend.accountId=…) > AIOPS_* env >
// config/accounts.json > the default declared in config/accounts.json.template.
// Missing, placeholder, or malformed values throw here, naming the JSON path —
// which replaces the one-off escalationEmail check this file used to carry.
const config = loadAccounts({ context: (k) => app.node.tryGetContext(k) });

new AgentsInfraStack(app, 'AgentsInfraStack', {
  synthesizer: synthesizer(),
  env: {
    account: config.ops.accountId,
    region: config.ops.region,
  },
  description: 'AI Ops PoC — fallback agent runtimes, KB, report store, webhook bridge, SSM switches, trust role (OPS account)',
  backendAccountId: config.backend.accountId,
  frontendAccountId: config.frontend.accountId,
  peer: config.peer,
  skillsEnabled: config.skillsEnabled,
  // The real address lives only in the git-ignored config/accounts.json.
  escalationEmail: config.ops.escalationEmail,
  modelId: config.bedrock.modelId,
  escalationMode: config.escalation.mode,
});
