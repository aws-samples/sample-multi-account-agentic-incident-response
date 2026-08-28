#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AgentSpacesStack } from '../lib/agent-spaces-stack';
// Cdk_Config_Loader — the only reader of config/accounts.json.
import { loadAccounts } from '../../config/accounts-config';

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

// Precedence: cdk context (-c ops.accountId=…) > AIOPS_* env >
// config/accounts.json > the default declared in config/accounts.json.template.
const config = loadAccounts({ context: (k) => app.node.tryGetContext(k) });

// Context flag: deploy associations only in phase 2 (after agent roles exist in FE/BE)
const enableAssociations =
  app.node.tryGetContext('ENABLE_ASSOCIATIONS') === 'true';

new AgentSpacesStack(app, 'AgentSpacesStack', {
  synthesizer: synthesizer(),
  env: {
    account: config.ops.accountId,
    region: config.ops.region,
  },
  description:
    'AI Ops PoC — AWS DevOps Agent Agent Spaces, operator apps, OPS monitor roles, SSM exports (OPS account)',
  frontendAccountId: config.frontend.accountId,
  backendAccountId: config.backend.accountId,
  enableAssociations,
  // Manual console step (Operator Access tab) — surfaced as a stack output.
  operatorFederationIdentifier: config.operator.federationIdentifier,
});
