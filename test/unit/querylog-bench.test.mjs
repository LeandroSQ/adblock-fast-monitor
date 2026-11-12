// SPDX-License-Identifier: Apache-2.0
// Cost of one poll in the browser (P4 budget: parse, classify
// and list at most 20 ms per poll of 900 entries). Measures the real
// querylog.js on a full 900-entry `log read` reply on top of a full table
// (500 rows), then rows() and stats(). The assertion is deliberately
// generous (shared CI hosts); the measured median is reported.
import assert from 'node:assert/strict';
import test from 'node:test';
import { performance } from 'node:perf_hooks';
import { ql, reply } from './querylog-load.mjs';

const T0 = 1794354461000;

// A realistic mix from the captured fixtures: blocked, forwarded, cached,
// CNAME chains, multi-record replies, other daemons' lines.
function entries(serial0, n) {
  const out = [];
  let s = serial0;
  while (out.length < n) {
    const c = `10.0.${s % 200}.${s % 250}`, h = `dnsmasq[1]: ${s} ${c}/${40000 + (s % 20000)} `;
    const t = T0 + s * 20;
    switch (s % 5) {
    case 0:
      out.push([`${h}query[A] ads${s}.tracker.example.test from ${c}`, t], [`${h}config ads${s}.tracker.example.test is NXDOMAIN`, t]);
      break;
    case 1:
      out.push([`${h}query[AAAA] www${s}.example.org from ${c}`, t], [`${h}forwarded www${s}.example.org to 192.0.2.53`, t],
        [`${h}reply www${s}.example.org is 2001:db8::${s % 999}`, t + 15]);
      break;
    case 2:
      out.push([`${h}query[A] cdn${s}.example.net from ${c}`, t], [`${h}forwarded cdn${s}.example.net to 192.0.2.53`, t],
        [`${h}reply cdn${s}.example.net is <CNAME>`, t + 30], [`${h}reply edge${s}.example.net is <CNAME>`, t + 30],
        [`${h}reply node${s}.example.net is 198.51.100.${s % 250}`, t + 30], [`${h}reply node${s}.example.net is 198.51.100.${(s + 1) % 250}`, t + 30]);
      break;
    case 3:
      out.push([`${h}query[HTTPS] api${s}.example.com from ${c}`, t], [`${h}cached api${s}.example.com is NODATA-IPv6`, t]);
      break;
    default:
      out.push([`odhcpd[1967]: rfc9096: br-lan: piofile updated ${s}`, t], [`${h}query[A] host${s}.lan from ${c}`, t],
        [`${h}config host${s}.lan is NXDOMAIN`, t]);
    }
    s++;
  }
  return out.slice(0, n);
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[s.length >> 1];
}

test('bench: one poll of 900 entries on a full table (parse + classify + rows + stats)', (t) => {
  const first = reply(entries(1, 900), { id: 1 });
  const times = [], full = [];
  for (let i = 0; i < 40; i++) {
    const st = ql.create({ local_domains: ['lan'] });
    let t0 = performance.now();
    ql.ingest(st, first);
    ql.rows(st);
    ql.stats(st);
    full.push(performance.now() - t0);

    const next = reply(entries(1000, 900), { id: 901 });
    t0 = performance.now();
    const r = ql.ingest(st, next);
    const rows = ql.rows(st);
    ql.stats(st);
    times.push(performance.now() - t0);
    assert.equal(r.missed, 0);
    assert.equal(rows.length, 500);
  }
  const ms = median(times.slice(5)), first900 = median(full.slice(5));
  t.diagnostic(`median ${ms.toFixed(2)} ms per 900-entry poll on a full table; first load ${first900.toFixed(2)} ms`);
  assert.ok(ms < 100, `median ${ms} ms`);
});
