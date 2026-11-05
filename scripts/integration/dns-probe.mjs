import { execFileSync } from 'node:child_process';

const [host, port] = process.argv.slice(2);
if (!host || !port) throw new Error('Usage: dns-probe.mjs HOST SSH_PORT [fixtures...]');

const samples = [];
for (let index = 0; index < 20; index += 1) {
  const started = performance.now();
  const answer = execFileSync('dig', ['+tries=1', '+time=2', '+short', '@127.0.0.1', '-p', '5353', 'ads.example.test'], { encoding: 'utf8' }).trim();
  if (answer !== '0.0.0.0') throw new Error(`expected deterministic dnsmasq answer, received "${answer}"`);
  samples.push(performance.now() - started);
}
samples.sort((left, right) => left - right);
const totalMs = samples.reduce((sum, sample) => sum + sample, 0);
console.log(JSON.stringify({
  p95Ms: Number(samples[Math.ceil(samples.length * 0.95) - 1].toFixed(3)),
  throughputQps: Number((samples.length / (totalMs / 1000)).toFixed(3)),
  samples
}));
