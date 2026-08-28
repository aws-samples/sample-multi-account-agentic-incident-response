/**
 * Type surface for the Cdk_Config_Loader implemented in `accounts-config.js`.
 *
 * Hand-written rather than emitted: the implementation is CommonJS because all
 * four CDK apps set `"rootDir": "."`, which puts a `.ts` file at `config/`
 * outside every app's rootDir (TS6059). Declaration files are exempt from
 * rootDir because they are never emitted, so this file type-checks the call
 * sites without any tsconfig change.
 */

export interface AccountEntry {
  accountId: string;
  region: string;
  profile: string;
}

export interface OpsEntry extends AccountEntry {
  escalationEmail: string;
}

export interface UpstreamEntry {
  org: string;
  repo: string;
  ref: string;
}

export type PeerMode = 'devops' | 'kb' | 'both';
export type EscalationMode = 'always' | 'auto';

export interface AccountsConfig {
  backend: AccountEntry;
  frontend: AccountEntry;
  ops: OpsEntry;
  upstream: UpstreamEntry;
  peer: PeerMode;
  skillsEnabled: boolean;
  operator: { federationIdentifier: string };
  bedrock: { modelId: string };
  escalation: { mode: EscalationMode };
}

export interface LoadAccountsOptions {
  /** Usually `(k) => app.node.tryGetContext(k)`. Keys are dotted JSON paths. */
  context?: (key: string) => unknown;
  /** Defaults to `process.env`. Canonical names are `AIOPS_<PATH>`. */
  env?: Record<string, string | undefined>;
  /** Defaults to `config/accounts.json`; the template is read alongside it. */
  configPath?: string;
}

/**
 * Resolve every Replicator_Input, applying context > env > file > template
 * default. Throws naming the JSON path when a required input is missing, still
 * holds a placeholder value, or fails the `format` / `allowed` metadata the
 * template declares for it.
 */
export declare function loadAccounts(opts?: LoadAccountsOptions): AccountsConfig;

/** The config paths this loader reads, in template order (check C3 consumes it). */
export declare const FIELDS: string[];

/** Value shapes that mean "not supplied yet" (mirrors scripts/lib/config.sh). */
export declare const PLACEHOLDER_PATTERNS: RegExp[];

/** Formats where equality with the template proves the field is unedited. */
export declare const TEMPLATE_EQUALITY_FORMATS: string[];

/** Shape a value must have for `format: "accountId"` (mirrors scripts/lib/config.sh). */
export declare const ACCOUNT_ID_PATTERN: RegExp;

/** Shape a value must have for `format: "email"` (mirrors scripts/lib/config.sh). */
export declare const EMAIL_PATTERN: RegExp;

/**
 * Throw unless `value` satisfies the `format` and `allowed` metadata the
 * template declares for `fieldPath`.
 */
export declare function validateValue(
  fieldPath: string,
  value: unknown,
  template: unknown,
  label: string,
): void;

/** True when `value` is an unedited placeholder for `fieldPath`. */
export declare function isPlaceholder(
  fieldPath: string,
  value: unknown,
  template: unknown,
): boolean;

/** `ops.region` -> `AIOPS_OPS_REGION`. */
export declare function envNameFor(fieldPath: string): string;
