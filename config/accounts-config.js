'use strict';

/**
 * Cdk_Config_Loader — the single place a CDK app reads config/accounts.json.
 *
 * Written as CommonJS with a hand-written sibling `accounts-config.d.ts`
 * on purpose: all four CDK apps set `"rootDir": "."` in their tsconfig, so a
 * `.ts` file living at `config/` is outside every app's rootDir and `tsc` /
 * `ts-node` reject it (TS6059). Declaration files are exempt from rootDir
 * because they are never emitted, so `.js` + `.d.ts` gives full type-checking
 * at the call site with zero tsconfig churn and no build step.
 *
 * Resolution precedence (Requirement 2.1, with CDK context standing in for the
 * environment-variable level per Requirement 4.4):
 *
 *   context (cdk -c <json.path>=<value>)  >  environment (AIOPS_*)  >
 *   config/accounts.json  >  default declared in config/accounts.json.template
 *
 * Required/optional status and defaults are read from the template's `_doc`
 * block, never restated here — adding a field to the template is the only
 * change needed for the loader to honour it.
 */

const fs = require('fs');
const path = require('path');

const CONFIG_BASENAME = 'accounts.json';
const TEMPLATE_BASENAME = 'accounts.json.template';
const ENV_PREFIX = 'AIOPS_';

/**
 * The config paths this loader reads, in template order. Exported so
 * `scripts/check-parameters.sh` check C3 can assert they are a subset of the
 * paths the template declares. This is the loader's declared read set: it is
 * deliberately written out rather than derived from the template, because a
 * derived list would make C3 vacuously true.
 */
const FIELDS = [
  'backend.accountId',
  'backend.region',
  'backend.profile',
  'frontend.accountId',
  'frontend.region',
  'frontend.profile',
  'ops.accountId',
  'ops.region',
  'ops.profile',
  'ops.escalationEmail',
  'upstream.org',
  'upstream.repo',
  'upstream.ref',
  'peer',
  'skillsEnabled',
  'operator.federationIdentifier',
  'bedrock.modelId',
  'escalation.mode',
];

/**
 * Shapes a value has when the Replicator has not edited it yet. These mirror
 * `_CONFIG_PLACEHOLDER_ID_RE` and `_CONFIG_PLACEHOLDER_PREFIX_RE` in
 * `scripts/lib/config.sh` so the two resolvers cannot disagree about what
 * counts as unset.
 */
const PLACEHOLDER_PATTERNS = [
  /^(1{12}|2{12}|3{12})$/,
  /^(REPLACE_WITH_|your-)/,
];

/**
 * Formats where the template's own value can never legitimately appear in a
 * real configuration, so equality with the template proves the field is still
 * unedited. Mirrors `_config__template_equality_applies` in
 * `scripts/lib/config.sh`: a profile name or a region in a real config commonly
 * equals the template's (this PoC's own deployment uses `backend-app`,
 * `frontend-app`, `monitoring` and `us-east-1`), so those are judged by the
 * placeholder patterns alone.
 */
const TEMPLATE_EQUALITY_FORMATS = ['accountId', 'email'];

/**
 * Shapes a value must have for the `format` its `_doc` entry declares. Which
 * field carries which format is never restated here — it is read from the
 * template, so a field added there is validated with no change to this file.
 *
 * These mirror `_CONFIG_ACCOUNT_ID_RE` / `_CONFIG_EMAIL_RE` and
 * `_config__validate` in `scripts/lib/config.sh` so the two resolvers cannot
 * disagree about which values are usable, the same way the placeholder rule is
 * cross-referenced above.
 *
 * `region`, `profile` and `string` are deliberately shape-free beyond "non-empty
 * after trimming": a newly launched AWS region must not require a change here.
 */
const ACCOUNT_ID_PATTERN = /^[0-9]{12}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/** `ops.region` -> `AIOPS_OPS_REGION`. Derived, never declared. */
function envNameFor(fieldPath) {
  return ENV_PREFIX + fieldPath.replace(/\./g, '_').toUpperCase();
}

function getPath(obj, fieldPath) {
  let cursor = obj;
  for (const segment of fieldPath.split('.')) {
    if (cursor === null || typeof cursor !== 'object' || !(segment in cursor)) {
      return undefined;
    }
    cursor = cursor[segment];
  }
  return cursor;
}

function setPath(obj, fieldPath, value) {
  const segments = fieldPath.split('.');
  let cursor = obj;
  for (const segment of segments.slice(0, -1)) {
    if (typeof cursor[segment] !== 'object' || cursor[segment] === null) {
      cursor[segment] = {};
    }
    cursor = cursor[segment];
  }
  cursor[segments[segments.length - 1]] = value;
}

function readJson(filePath, role, hint) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${role} not found at ${filePath}. ${hint}`);
  }
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf-8');
  } catch (err) {
    throw new Error(`${role} at ${filePath} could not be read: ${err.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`${role} at ${filePath} is not valid JSON: ${err.message}`);
  }
}

function docEntry(template, fieldPath) {
  const doc = template._doc;
  const entry = doc && typeof doc === 'object' ? doc[fieldPath] : undefined;
  return entry && typeof entry === 'object' ? entry : undefined;
}

function isRequired(template, fieldPath) {
  const entry = docEntry(template, fieldPath);
  // Undeclared fields are treated as required: an undeclared read is a
  // check-parameters C3 failure, and failing loudly beats inventing a default.
  return entry === undefined ? true : entry.required === true;
}

/**
 * True when `value` is a value the Replicator has not supplied yet — the same
 * rule as `config::is_placeholder` in `scripts/lib/config.sh`:
 *
 *  1. The value has a placeholder shape (`111111111111`, `REPLACE_WITH_…`,
 *     `your-…`). Applied to every field.
 *  2. The value is byte-identical to the template's own value for that path,
 *     and that path's declared format is one the template cannot share with a
 *     real configuration (`accountId`, `email`).
 */
function isPlaceholder(fieldPath, value, template) {
  if (typeof value !== 'string' || value === '') {
    return false;
  }
  if (PLACEHOLDER_PATTERNS.some((pattern) => pattern.test(value))) {
    return true;
  }
  const entry = docEntry(template, fieldPath);
  const format = entry ? entry.format : undefined;
  if (!TEMPLATE_EQUALITY_FORMATS.includes(format)) {
    return false;
  }
  const templateValue = getPath(template, fieldPath);
  return typeof templateValue === 'string' && templateValue !== '' && value === templateValue;
}

function isSupplied(value) {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value === 'string') {
    return value.trim() !== '';
  }
  return true;
}

/** Where a winning candidate came from, phrased for an error message. */
function sourceLabel(winner) {
  return winner.origin === 'file' ? `config/${CONFIG_BASENAME}` : winner.detail;
}

/** The one error shape for "a value was supplied but it is not usable". */
function invalidValueError(fieldPath, value, label, expected) {
  return new Error(
    `config/accounts.json: ${fieldPath} has an invalid value "${value}" `
    + `(from ${label}). ${expected}`,
  );
}

function coerce(fieldPath, value, template, label) {
  const entry = docEntry(template, fieldPath);
  const format = entry ? entry.format : undefined;
  if (format === 'boolean') {
    if (typeof value === 'boolean') {
      return value;
    }
    const text = String(value).trim().toLowerCase();
    if (text === 'true') return true;
    if (text === 'false') return false;
    throw invalidValueError(
      fieldPath, value, label, 'Expected true or false (declared format: boolean).',
    );
  }
  if (typeof value === 'string') {
    return value.trim();
  }
  return value;
}

/**
 * Check a resolved value against the `format` and the `allowed` domain its
 * `_doc` entry declares. Throws naming the JSON path, the offending value, the
 * source, and the expected form. Same rules as `_config__validate` in
 * `scripts/lib/config.sh` — KEEP THE TWO IN SYNC.
 */
function validateValue(fieldPath, value, template, label) {
  const entry = docEntry(template, fieldPath);
  const format = (entry && entry.format) || 'string';
  const allowed = entry && Array.isArray(entry.allowed) ? entry.allowed : undefined;
  const text = typeof value === 'string' ? value.trim() : String(value);

  let expected;
  if (format === 'accountId') {
    if (!ACCOUNT_ID_PATTERN.test(text)) {
      expected = 'Expected exactly 12 decimal digits (declared format: accountId).';
    }
  } else if (format === 'email') {
    if (!EMAIL_PATTERN.test(text)) {
      expected = 'Expected an address of the form name@example.com (declared format: email).';
    }
  } else if (format === 'boolean') {
    if (typeof value !== 'boolean') {
      expected = 'Expected true or false (declared format: boolean).';
    }
  } else if (text === '') {
    // region, profile, string: non-empty is the whole rule. No region regex —
    // a region AWS launches tomorrow must resolve without a change here.
    expected = `Expected a non-empty value (declared format: ${format}).`;
  }

  if (!expected && allowed && !allowed.map(String).includes(text)) {
    expected = `Expected one of: ${allowed.map(String).join(', ')}.`;
  }

  if (expected) {
    throw invalidValueError(fieldPath, value, label, expected);
  }
}

function resolveOne(fieldPath, sources) {
  const { context, env, config, template } = sources;

  const candidates = [
    { origin: 'context', detail: fieldPath, value: context ? context(fieldPath) : undefined },
    { origin: 'env', detail: envNameFor(fieldPath), value: env ? env[envNameFor(fieldPath)] : undefined },
    { origin: 'file', detail: CONFIG_BASENAME, value: getPath(config, fieldPath) },
  ];

  const declared = docEntry(template, fieldPath);
  if (declared && 'default' in declared) {
    candidates.push({ origin: 'default', detail: TEMPLATE_BASENAME, value: declared.default });
  } else if (!isRequired(template, fieldPath)) {
    // Optional without a declared default: fall back to the template's own
    // value tree. check-parameters C1 rejects this state, so it is a safety net.
    candidates.push({ origin: 'default', detail: TEMPLATE_BASENAME, value: getPath(template, fieldPath) });
  }

  const winner = candidates.find((candidate) => isSupplied(candidate.value));

  if (!winner) {
    throw new Error(
      `config/accounts.json: ${fieldPath} is required but not set. `
      + `Set it in config/accounts.json (see config/${TEMPLATE_BASENAME}), `
      + `or pass -c ${fieldPath}=<value>, or set ${envNameFor(fieldPath)}.`,
    );
  }

  const label = sourceLabel(winner);
  const value = coerce(fieldPath, winner.value, template, label);

  // A value that is still a placeholder is never usable, whether the field is
  // required or optional — but a template default is not a placeholder by
  // virtue of coming from the template. Same guard as scripts/lib/config.sh.
  if (winner.origin !== 'default' && isPlaceholder(fieldPath, value, template)) {
    throw new Error(
      `config/accounts.json: ${fieldPath} still holds the placeholder value `
      + `"${value}" (from ${label}). `
      + `Replace it with the value for your own account — see config/${TEMPLATE_BASENAME}.`,
    );
  }

  // Declared format and enum domain apply to a value from any source (context,
  // env, file). A template default is trusted, for the same reason the
  // placeholder guard above skips defaults.
  if (winner.origin !== 'default') {
    validateValue(fieldPath, value, template, label);
  }

  return value;
}

/**
 * Resolve every Replicator_Input a CDK app needs.
 *
 * @param {{ context?: (key: string) => unknown, env?: Record<string, string|undefined>, configPath?: string }} [opts]
 * @returns {object} AccountsConfig
 */
function loadAccounts(opts) {
  const options = opts || {};
  const configPath = options.configPath
    ? path.resolve(options.configPath)
    : path.resolve(__dirname, CONFIG_BASENAME);
  const templatePath = path.join(path.dirname(configPath), TEMPLATE_BASENAME);

  const template = readJson(
    templatePath,
    `config/${TEMPLATE_BASENAME}`,
    'It is committed to the repository — restore it before deploying.',
  );
  const config = readJson(
    configPath,
    `config/${CONFIG_BASENAME}`,
    `Run scripts/setup-config.sh, or copy config/${TEMPLATE_BASENAME} to `
    + `config/${CONFIG_BASENAME} and replace every placeholder.`,
  );

  const env = options.env || process.env;
  const context = typeof options.context === 'function' ? options.context : undefined;
  const sources = { context, env, config, template };

  const resolved = {};
  for (const fieldPath of FIELDS) {
    setPath(resolved, fieldPath, resolveOne(fieldPath, sources));
  }
  return resolved;
}

module.exports = {
  loadAccounts,
  FIELDS,
  PLACEHOLDER_PATTERNS,
  TEMPLATE_EQUALITY_FORMATS,
  ACCOUNT_ID_PATTERN,
  EMAIL_PATTERN,
  isPlaceholder,
  validateValue,
  envNameFor,
};
