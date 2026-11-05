import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { projectRoot, readManifest } from './lib/manifest.mjs';

const manifest = await readManifest();
const resultPath = resolve(projectRoot, manifest.requiredAdapters.performance);
const measurementRequired = process.env.PERFORMANCE_REQUIRE_MEASURED === '1';
let results;
try {
  results = JSON.parse(await readFile(resultPath, 'utf8'));
} catch (error) {
  console.error(`Cannot evaluate performance gate: ${resultPath} is required (${error.message}).`);
  process.exit(1);
}

const failures = [];
const state = results.measurementState;
const p0 = results.p0;
if (!['proposed', 'measured'].includes(state)) {
  failures.push('measurementState must be "proposed" or "measured"');
}
if (!p0 || p0.classification !== state || typeof p0.label !== 'string' || !p0.label.includes(`P0 ${state}`)) {
  failures.push('p0 must label the result consistently as "P0 proposed" or "P0 measured"');
}
if (state === 'measured') {
  if (typeof results.measuredAt !== 'string' || Number.isNaN(Date.parse(results.measuredAt))) {
    failures.push('measured results require an ISO-8601 measuredAt timestamp');
  }
  if (!results.environment || results.environment.kind === 'unmeasured') {
    failures.push('measured results require a real isolated environment description');
  }
}
for (const [metric, budget] of Object.entries(manifest.performanceBudgets)) {
  if (!Number.isFinite(results[metric])) failures.push(`${metric} is missing or not numeric`);
  else if (results[metric] > budget) failures.push(`${metric}=${results[metric]} exceeds budget ${budget}`);
}
if (measurementRequired && state !== 'measured') {
  failures.push('a measured result is required in this environment; proposed baselines are not accepted');
}
if (failures.length) {
  console.error(`Performance regression gate failed:\n- ${failures.join('\n- ')}`);
  process.exit(1);
}
if (state === 'proposed') {
  if (process.env.OPENWRT_PERFORMANCE_MEASURE) {
    console.error(
      'Performance measurement prerequisite is available, but only a proposed baseline exists. ' +
      'Run npm run test:performance:measure before this gate.'
    );
    process.exit(1);
  }
  console.log(
    'SKIP (P0 proposed baseline): no isolated OpenWrt measurement adapter is available; ' +
    'this is not a measured performance pass.'
  );
} else {
  console.log('Performance regression gate passed with a measured P0 result.');
}
