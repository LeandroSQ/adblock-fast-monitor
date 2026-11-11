// SPDX-License-Identifier: Apache-2.0
// JSON Schemas of the replies of `luci.adblock-fast-monitor` (docs/CONTRACT.md
// §6.1-§6.3, §7.1, api 2), strict: unknown fields fail. Used by the browser
// suite on replies captured from the real guest backend and by the unit tests
// on the hand-written `info` fixtures. Not a test file.
import Ajv from 'ajv';

const str = { type: 'string' };
const strOrNull = { type: ['string', 'null'] };
const bool = { type: 'boolean' };
const int = { type: 'integer' };
const intOrNull = { type: ['integer', 'null'] };
const jobId = { type: 'string', pattern: '^j[0-9]{10}-[0-9a-f]{4}$' };
const obj = (properties, required = Object.keys(properties)) =>
  ({ type: 'object', additionalProperties: false, properties, required });

const OP = { enum: ['allow', 'block'] };
const CHANGE = { type: 'array', items: { enum: ['allow:add', 'allow:remove', 'block:add', 'block:remove'] }, maxItems: 2 };
const MODE = { enum: ['rebuild', 'persist-only'] };
const plan = { type: 'array', maxItems: 64, items: obj({ op: OP, domain: str, change: CHANGE }) };

const APPLY_ERRORS = ['invalid-request', 'batch-empty', 'batch-too-large', 'invalid-domain', 'protected-domain',
  'public-suffix', 'conflict', 'allow-overrides', 'adblock-fast-missing', 'external-config', 'unsupported-dns-mode',
  'pending-uci-changes', 'confirm-required', 'busy', 'uci-error', 'spawn-failed'];
const JOB_ERRORS = ['lock-failed', 'rebuild-failed', 'interrupted', 'start-timeout'];

const errorObj = (codes) => obj({ code: { enum: codes }, message: str, index: int, domain: str },
  ['code', 'message']);

export const info = obj({
  api: { const: 2 },
  ok: { const: true },
  monitor: obj({ query_logging: bool }),
  local_domains: { type: 'array', items: str },
  protected_suffixes: { type: 'array', items: str, minItems: 1 },
  logd: obj({ size_kib: int }),
  adblock_fast: obj({
    installed: bool, enabled: bool, status: strOrNull, dns: strOrNull, output_file: strOrNull,
    output_exists: bool, external_config: bool, pending_uci_changes: bool
  }),
  dnsmasq: obj({
    running: bool,
    instances: {
      type: 'array',
      items: obj({
        section: str, confdir: strOrNull, dropin: bool, uci_logqueries: bool, running: bool,
        logfacility_file: bool, reason: { const: 'confdir-invalid' }
      }, ['section', 'confdir', 'dropin', 'uci_logqueries', 'running', 'logfacility_file'])
    }
  }),
  warnings: { type: 'array', uniqueItems: true, items: { enum: ['query-logging-active', 'logd-to-flash', 'logd-remote'] } }
});

export const apply = {
  oneOf: [
    // queued
    obj({ api: { const: 2 }, ok: { const: true }, job_id: jobId, state: { const: 'queued' }, mode: MODE, plan }),
    // noop (also for a dry run)
    obj({ api: { const: 2 }, ok: { const: true }, noop: { const: true }, job_id: { type: 'null' }, mode: { enum: ['rebuild', 'persist-only', null] }, plan }),
    // dry run with changes
    obj({ api: { const: 2 }, ok: { const: true }, dry_run: { const: true }, noop: { const: false }, mode: MODE, plan }),
    // errors: extra fields only where §6.3 lists them
    obj({
      api: { const: 2 }, ok: { const: false }, error: errorObj(APPLY_ERRORS),
      job_id: { anyOf: [jobId, { type: 'null' }] }, mode: MODE, plan, persisted: bool
    }, ['api', 'ok', 'error'])
  ]
};

const answer = obj({ rcode: str, a: { type: 'array', items: str }, aaaa: { type: 'array', items: str } }, ['rcode']);
const jobItem = obj({
  op: OP, domain: str, change: CHANGE, expect: { enum: ['allowed', 'blocked'] },
  result: { enum: ['pending', 'ok', 'mismatch', 'unverified', 'skipped'] },
  observed: { enum: ['allowed', 'blocked', 'unknown', null] },
  answer: { anyOf: [answer, { type: 'null' }] },
  reason: { enum: ['parent-blocked', 'still-listed', 'not-blocked', 'dns-error', 'dns-mode-unsupported', null] }
});
const job = obj({
  id: jobId,
  state: { enum: ['queued', 'applying', 'verifying', 'applied', 'partial', 'failed'] },
  mode: MODE,
  phase: { enum: [null, 'rebuild', 'verify'] },
  created_at: int, started_at: intOrNull, finished_at: intOrNull,
  persisted: bool,
  adblock_fast_status: strOrNull,
  error: { anyOf: [{ type: 'null' }, obj({ code: { enum: JOB_ERRORS }, message: str })] },
  items: { type: 'array', maxItems: 64, items: jobItem }
});

export const jobReply = {
  oneOf: [
    obj({ api: { const: 2 }, ok: { const: true }, job: { anyOf: [job, { type: 'null' }] } }),
    obj({ api: { const: 2 }, ok: { const: false }, error: errorObj(['not-found']) })
  ]
};

const ajv = new Ajv({ allErrors: true, strict: true, allowUnionTypes: true });
const compiled = { info: ajv.compile(info), apply: ajv.compile(apply), job: ajv.compile(jobReply) };

/** Validates a reply of `method`; returns [] or a list of "path message" strings. */
export function validate(method, reply) {
  const fn = compiled[method];
  if (!fn) throw new Error(`no schema for ${method}`);
  return fn(reply) ? [] : fn.errors.map((e) => `${e.instancePath || '/'} ${e.message}${e.params ? ' ' + JSON.stringify(e.params) : ''}`);
}
