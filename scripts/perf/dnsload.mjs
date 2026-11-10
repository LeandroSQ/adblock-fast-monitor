#!/usr/bin/env node
// Open-loop UDP DNS load generator for the P0 harness (docs/performance.md).
// Sends A queries at a fixed rate from the host, so the router sees a LAN
// source address (QEMU user networking: 10.0.2.2), never 127.0.0.1.
//
//   node scripts/perf/dnsload.mjs --port N --qps Q --seconds S --tag T [--host 127.0.0.1]
//        [--mix unique:50,cached:30,blocked:20] [--timeout-ms 2000] [--out FILE]
//
// Name classes (answered by the guest's local fixtures, never the WAN):
//   unique   u-<tag>-<n>.perf.test        forwarded to the local responder -> "reply ... is 192.0.2.1"
//   cached   c<k>.perf.test (k < 20)      answered from dnsmasq's cache    -> "cached ..."
//   blocked  b-<tag>-<n>.perf-block.test  local=/perf-block.test/          -> "config ... is NXDOMAIN"
// Prints (and writes with --out) one JSON document with every latency sample.
import dgram from 'node:dgram';
import { writeFileSync } from 'node:fs';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, value, index, all) => {
  if (value.startsWith('--')) acc.push([value.slice(2), all[index + 1]]);
  return acc;
}, []));
const host = args.host ?? '127.0.0.1';
const port = Number(args.port);
const qps = Number(args.qps);
const seconds = Number(args.seconds);
const tag = String(args.tag ?? Date.now().toString(36));
const timeoutMs = Number(args['timeout-ms'] ?? 2000);
const mix = Object.fromEntries(String(args.mix ?? 'unique:50,cached:30,blocked:20')
  .split(',').map(part => part.split(':')).map(([name, weight]) => [name, Number(weight)]));
if (!(port > 0 && qps > 0 && seconds > 0) || !/^[a-z0-9-]{1,20}$/.test(tag)) {
  console.error('usage: dnsload.mjs --port N --qps Q --seconds S --tag [a-z0-9-]+ [--host H] [--mix ...] [--out FILE]');
  process.exit(2);
}

const classes = Object.entries(mix).filter(([, weight]) => weight > 0);
const weightSum = classes.reduce((sum, [, weight]) => sum + weight, 0);
// Deterministic interleaving: query i gets the class whose cumulative share it falls in.
function classFor(index) {
  let slot = (index * 37) % weightSum;
  for (const [name, weight] of classes) {
    if (slot < weight) return name;
    slot -= weight;
  }
  return classes[0][0];
}
function nameFor(kind, index) {
  if (kind === 'cached') return `c${index % 20}.perf.test`;
  if (kind === 'blocked') return `b-${tag}-${index}.perf-block.test`;
  return `u-${tag}-${index}.perf.test`;
}
function encodeQuery(id, name) {
  const labels = name.split('.').map(label => Buffer.concat([Buffer.from([label.length]), Buffer.from(label)]));
  const header = Buffer.alloc(12);
  header.writeUInt16BE(id, 0);
  header.writeUInt16BE(0x0100, 2); // RD
  header.writeUInt16BE(1, 4);
  return Buffer.concat([header, ...labels, Buffer.from([0, 0, 1, 0, 1])]);
}

const socket = dgram.createSocket('udp4');
const outstanding = new Map();
const samples = [];
const perClass = {};
const rcodes = {};
const answered = {};
let sent = 0;
let lost = 0;
let mismatched = 0;
let nextId = 1;

socket.on('message', message => {
  if (message.length < 12) return;
  const id = message.readUInt16BE(0);
  const entry = outstanding.get(id);
  if (!entry) { mismatched += 1; return; }
  outstanding.delete(id);
  clearTimeout(entry.timer);
  const ms = Number(process.hrtime.bigint() - entry.sentAt) / 1e6;
  const rcode = message.readUInt8(3) & 0x0f;
  rcodes[rcode] = (rcodes[rcode] ?? 0) + 1;
  const answers = (answered[entry.kind] ??= { with_answer: 0, empty: 0 });
  if (message.readUInt16BE(6) > 0) answers.with_answer += 1; else answers.empty += 1;
  samples.push(Math.round(ms * 1000) / 1000);
  (perClass[entry.kind] ??= []).push(ms);
});

function send(index) {
  const kind = classFor(index);
  let id = nextId;
  while (outstanding.has(id)) id = (id % 65535) + 1;
  nextId = (id % 65535) + 1;
  const entry = { kind, sentAt: process.hrtime.bigint() };
  entry.timer = setTimeout(() => { outstanding.delete(id); lost += 1; }, timeoutMs);
  outstanding.set(id, entry);
  socket.send(encodeQuery(id, nameFor(kind, index)), port, host);
  sent += 1;
}

function percentile(sorted, q) {
  if (!sorted.length) return null;
  return sorted[Math.max(0, Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1))];
}
function summary(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mean = sorted.reduce((sum, value) => sum + value, 0) / (sorted.length || 1);
  const round = value => (value == null ? null : Math.round(value * 1000) / 1000);
  return { n: sorted.length, p50: round(percentile(sorted, 0.5)), p95: round(percentile(sorted, 0.95)),
    p99: round(percentile(sorted, 0.99)), max: round(sorted.at(-1)), mean: round(mean) };
}

const total = Math.round(qps * seconds);
const startedAt = process.hrtime.bigint();
const startedWall = new Date().toISOString();
let index = 0;
await new Promise(resolve => {
  const tick = () => {
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    const due = Math.min(total, Math.floor((elapsedMs * qps) / 1000) + 1);
    while (index < due) send(index++);
    if (index >= total) return resolve();
    const nextAt = (index * 1000) / qps;
    setTimeout(tick, Math.max(0, nextAt - elapsedMs));
  };
  tick();
});
const sendSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
await new Promise(resolve => {
  const wait = () => (outstanding.size === 0 ? resolve() : setTimeout(wait, 20));
  wait();
});
socket.close();

const result = {
  tool: 'dnsload', host, port, tag, qps_target: qps, seconds_target: seconds, started_at: startedWall,
  send_seconds: Math.round(sendSeconds * 1000) / 1000, qps_achieved: Math.round((sent / sendSeconds) * 100) / 100,
  mix, timeout_ms: timeoutMs, sent, received: samples.length, lost, mismatched, rcodes, answers_by_class: answered,
  latency_ms: summary(samples),
  latency_ms_by_class: Object.fromEntries(Object.entries(perClass).map(([kind, values]) => [kind, summary(values)])),
  samples_ms: samples
};
if (args.out) writeFileSync(args.out, `${JSON.stringify(result)}\n`);
const { samples_ms: _omit, ...brief } = result;
console.log(JSON.stringify(brief));
