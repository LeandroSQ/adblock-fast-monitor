// SPDX-License-Identifier: Apache-2.0
// Loads the real LuCI resource
// root/www/luci-static/resources/adblock-fast-monitor/querylog.js the way
// luci.js does (the file is the body of a factory whose return value is a
// class instantiated once), like test/unit/ui-model.test.mjs, plus helpers
// that build `log read` replies. Not a test file.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = readFileSync(fileURLToPath(new URL(
  '../../root/www/luci-static/resources/adblock-fast-monitor/querylog.js', import.meta.url)), 'utf8');
const baseclass = { extend(proto) { return function QueryLog() { Object.assign(this, proto); }; } };
// eslint-disable-next-line no-new-func
const Factory = new Function('window', 'document', 'L', 'baseclass', source);
const Cls = Factory({}, {}, {}, baseclass);
export const ql = new Cls();

export const fixture = (name) => JSON.parse(readFileSync(fileURLToPath(new URL(
  `../fixtures/logread/${name}`, import.meta.url)), 'utf8'));
export const fixtureText = (name) => readFileSync(fileURLToPath(new URL(
  `../fixtures/${name}`, import.meta.url)), 'utf8');

// A `log read` reply: msgs are strings or [msg, timeMs]; ids are consecutive
// from `id`; time defaults to `time` (ms) for every entry.
export function reply(msgs, { id = 100, time = 1794354461000, priority = 30 } = {}) {
  return {
    log: msgs.map((m, i) => {
      const [msg, t] = Array.isArray(m) ? m : [m, time];
      return { msg, id: id + i, priority, source: 1, time: t };
    })
  };
}

const MONTHS = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };
const LOGREAD = /^[A-Z][a-z]{2} ([A-Z][a-z]{2}) ([ 0-9][0-9]) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4}) [a-z0-9]+\.[a-z]+ (.*)$/;

// `logread` text (test/fixtures/dnsmasq/*.log, UTC) as the `log read` reply
// logd would have sent for the same entries.
export function replyFromLogread(text, firstId = 1) {
  const log = [];
  for (const line of text.split('\n')) {
    const m = LOGREAD.exec(line);
    if (!m) continue;
    const time = Date.UTC(+m[6], MONTHS[m[1]], +m[2].trim(), +m[3], +m[4], +m[5]);
    log.push({ msg: m[7], id: firstId + log.length, priority: 30, source: 1, time });
  }
  return { log };
}
