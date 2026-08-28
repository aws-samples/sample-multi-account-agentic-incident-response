/**
 * Cdk_Config_Loader tests — Requirements 4.1, 4.3, 4.4.
 */
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

// The loader is CommonJS at config/accounts-config.js with a hand-written
// sibling .d.ts — see the comment at the top of that file for why.
import { loadAccounts, FIELDS } from '../../../config/accounts-config';

const REPO_ROOT = path.resolve(__dirname, '../../..');
const TEMPLATE_SOURCE = path.join(REPO_ROOT, 'config/accounts.json.template');

// Synthetic account IDs, built at runtime so no 12-digit literal appears in
// this file. The canonical placeholders 1×12 / 2×12 / 3×12 cannot be used for
// a *valid* fixture: the loader rejects them by design, which is what the
// placeholder tests below assert.
const BE_ID = '4'.repeat(12);
const FE_ID = '5'.repeat(12);
const OPS_ID = '6'.repeat(12);
const PLACEHOLDER_ID = '1'.repeat(12);

interface Fixture {
  dir: string;
  configPath: string;
}

const fixtures: string[] = [];

function writeFixture(config: unknown): Fixture {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'accounts-config-'));
  fixtures.push(dir);
  fs.copyFileSync(TEMPLATE_SOURCE, path.join(dir, 'accounts.json.template'));
  const configPath = path.join(dir, 'accounts.json');
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
  return { dir, configPath };
}

/** A config with every required field supplied and no optional field set. */
function requiredOnlyConfig(): Record<string, unknown> {
  return {
    backend: { accountId: BE_ID, profile: 'be-cli-profile' },
    frontend: { accountId: FE_ID, profile: 'fe-cli-profile' },
    ops: {
      accountId: OPS_ID,
      profile: 'ops-cli-profile',
      escalationEmail: 'ops-team@example.com',
    },
    operator: { federationIdentifier: 'fixture-federation-id' },
  };
}

afterAll(() => {
  for (const dir of fixtures) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('loadAccounts precedence', () => {
  test('file value beats the template default', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).region = 'eu-west-1';
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.ops.region).toBe('eu-west-1');
  });

  test('environment beats the file', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).region = 'eu-west-1';
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({
      configPath,
      env: { AIOPS_OPS_REGION: 'ap-south-1' },
    });

    expect(resolved.ops.region).toBe('ap-south-1');
  });

  test('context beats the environment and the file', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).region = 'eu-west-1';
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({
      configPath,
      env: { AIOPS_OPS_REGION: 'ap-south-1' },
      context: (key) => (key === 'ops.region' ? 'us-east-2' : undefined),
    });

    expect(resolved.ops.region).toBe('us-east-2');
  });

  test('context supplies a required field the file omits', () => {
    const config = requiredOnlyConfig();
    delete (config.operator as Record<string, unknown>).federationIdentifier;
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({
      configPath,
      env: {},
      context: (key) => (key === 'operator.federationIdentifier' ? 'ctx-federation-id' : undefined),
    });

    expect(resolved.operator.federationIdentifier).toBe('ctx-federation-id');
  });
});

describe('loadAccounts template defaults', () => {
  test('an omitted profile resolves to its conventional default', () => {
    const config = requiredOnlyConfig();
    delete (config.backend as Record<string, unknown>).profile;
    delete (config.frontend as Record<string, unknown>).profile;
    delete (config.ops as Record<string, unknown>).profile;
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.backend.profile).toBe('backend-app');
    expect(resolved.frontend.profile).toBe('frontend-app');
    expect(resolved.ops.profile).toBe('monitoring');
  });

  test('an omitted optional field yields the template default', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.backend.region).toBe('us-east-1');
    expect(resolved.frontend.region).toBe('us-east-1');
    expect(resolved.ops.region).toBe('us-east-1');
    // Read the expected upstream block from the template rather than
    // hardcoding it. This test asserts the DEFAULTING MECHANISM, not a frozen
    // value, and `upstream.ref` is a deliberate commit pin — a floating "main"
    // would leave the upstream an unpinned dependency — so it is bumped from
    // time to time. Hardcoding the pin here is what made this test go stale.
    const templateDefaults = JSON.parse(fs.readFileSync(TEMPLATE_SOURCE, 'utf8'));
    expect(resolved.upstream).toEqual(templateDefaults.upstream);
    expect(resolved.peer).toBe('both');
    expect(resolved.skillsEnabled).toBe(true);
  });

  test('the new bedrock and escalation entries default from the template', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.bedrock.modelId).toBe('us.anthropic.claude-sonnet-4-5-20250929-v1:0');
    expect(resolved.escalation.mode).toBe('always');
  });

  test('a boolean field supplied as a string is coerced', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    const resolved = loadAccounts({
      configPath,
      env: { AIOPS_SKILLSENABLED: 'false' },
    });

    expect(resolved.skillsEnabled).toBe(false);
  });
});

describe('loadAccounts failures', () => {
  test('a missing required field throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    delete (config.ops as Record<string, unknown>).escalationEmail;
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/ops\.escalationEmail/);
  });

  test('an empty required field throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.operator as Record<string, unknown>).federationIdentifier = '   ';
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/operator\.federationIdentifier/);
  });

  test('a placeholder account ID throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.backend as Record<string, unknown>).accountId = PLACEHOLDER_ID;
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/backend\.accountId/);
    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/placeholder/);
  });

  test('a value left at the template placeholder throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).escalationEmail = 'REPLACE_WITH_TEAM_EMAIL';
    (config.operator as Record<string, unknown>).federationIdentifier = 'your-federation-identifier';
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/ops\.escalationEmail/);
  });

  test('a placeholder supplied by context is rejected too', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    expect(() => loadAccounts({
      configPath,
      env: {},
      context: (key) => (key === 'frontend.accountId' ? PLACEHOLDER_ID : undefined),
    })).toThrow(/frontend\.accountId/);
  });

  test('a profile equal to the template value is accepted, not read as a placeholder', () => {
    // The template ships this PoC's conventional CLI profile names as usable
    // values, so equality with the template is only evidence of an unedited
    // field for accountId and email formats — same rule as scripts/lib/config.sh.
    const template = JSON.parse(fs.readFileSync(TEMPLATE_SOURCE, 'utf-8'));
    const config = requiredOnlyConfig();
    (config.backend as Record<string, unknown>).profile = template.backend.profile;
    (config.ops as Record<string, unknown>).profile = template.ops.profile;
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.backend.profile).toBe(template.backend.profile);
    expect(resolved.ops.profile).toBe(template.ops.profile);
  });

  test('a missing config file throws naming both the file and the template', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'accounts-config-'));
    fixtures.push(dir);
    fs.copyFileSync(TEMPLATE_SOURCE, path.join(dir, 'accounts.json.template'));

    expect(() => loadAccounts({ configPath: path.join(dir, 'accounts.json'), env: {} }))
      .toThrow(/config\/accounts\.json\.template/);
  });
});

describe('loadAccounts value validation', () => {
  // A hand-edited config/accounts.json never passes through the Setup_Wizard, so
  // the loader applies the format / allowed metadata itself. These cases mirror
  // scripts/tests/test_config_resolver_failures.py — the two resolvers must
  // accept and reject the same values.
  const TEMPLATE = JSON.parse(fs.readFileSync(TEMPLATE_SOURCE, 'utf-8'));
  const PEER_ALLOWED: string[] = TEMPLATE._doc.peer.allowed;
  const MODE_ALLOWED: string[] = TEMPLATE._doc['escalation.mode'].allowed;

  test('an account ID one digit short throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.backend as Record<string, unknown>).accountId = '4'.repeat(11);
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/backend\.accountId/);
    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/12 decimal digits/);
  });

  test('an account ID one digit too long throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).accountId = '6'.repeat(13);
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/ops\.accountId/);
  });

  test('a malformed email throws naming its JSON path', () => {
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).escalationEmail = 'ops-team.example.com';
    const { configPath } = writeFixture(config);

    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/ops\.escalationEmail/);
    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/email/);
  });

  test('an out-of-domain peer throws listing the allowed values', () => {
    const config = requiredOnlyConfig();
    config.peer = 'nonsense';
    const { configPath } = writeFixture(config);

    for (const allowed of PEER_ALLOWED) {
      expect(() => loadAccounts({ configPath, env: {} })).toThrow(new RegExp(allowed));
    }
    expect(() => loadAccounts({ configPath, env: {} })).toThrow(/peer/);
  });

  test('a valid enum value from the file is accepted', () => {
    const config = requiredOnlyConfig();
    config.peer = PEER_ALLOWED[0];
    config.escalation = { mode: MODE_ALLOWED[1] };
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.peer).toBe(PEER_ALLOWED[0]);
    expect(resolved.escalation.mode).toBe(MODE_ALLOWED[1]);
  });

  test('an out-of-domain value supplied via context is rejected', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    expect(() => loadAccounts({
      configPath,
      env: {},
      context: (key) => (key === 'escalation.mode' ? 'whenever' : undefined),
    })).toThrow(/escalation\.mode/);
  });

  test('an out-of-domain value supplied via the environment is rejected', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    expect(() => loadAccounts({ configPath, env: { AIOPS_PEER: 'nonsense' } }))
      .toThrow(/peer/);
  });

  test('a region this repository has never used is accepted', () => {
    // No region allowlist: a region AWS adds must resolve with no code change.
    const config = requiredOnlyConfig();
    (config.ops as Record<string, unknown>).region = 'ap-northeast-3';
    const { configPath } = writeFixture(config);

    const resolved = loadAccounts({ configPath, env: {} });

    expect(resolved.ops.region).toBe('ap-northeast-3');
  });

  test('a non-boolean value for a boolean field is rejected', () => {
    const { configPath } = writeFixture(requiredOnlyConfig());

    expect(() => loadAccounts({ configPath, env: { AIOPS_SKILLSENABLED: 'yes' } }))
      .toThrow(/skillsEnabled/);
    expect(() => loadAccounts({ configPath, env: { AIOPS_SKILLSENABLED: 'yes' } }))
      .toThrow(/true or false/);
  });
});

describe('FIELDS', () => {
  test('every exported field path is declared in the template _doc block', () => {
    const template = JSON.parse(fs.readFileSync(TEMPLATE_SOURCE, 'utf-8'));
    const declared = Object.keys(template._doc).filter((key) => key !== '$');

    expect(FIELDS.filter((field) => !declared.includes(field))).toEqual([]);
  });
});
