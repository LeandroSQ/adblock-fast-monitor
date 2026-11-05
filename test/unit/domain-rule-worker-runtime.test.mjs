import assert from 'node:assert/strict';
import { chmod, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join, resolve } from 'node:path';
import test from 'node:test';

const execFileAsync = promisify(execFile);
const runtime = resolve(`test/.domain-rule-runtime-${process.pid}`);
const bin = join(runtime, 'bin');
const state = join(runtime, 'state');
const uciState = join(runtime, 'uci');
const psl = join(runtime, 'public_suffix_list.dat');
const init = join(runtime, 'adblock-fast');
const worker = join(runtime, 'worker');
const common = join(runtime, 'common.sh');

async function executable(path, content) {
  await writeFile(path, content);
  await chmod(path, 0o755);
}

async function run(action, domain, confirmation = '') {
  await execFileAsync('sh', [worker, action, domain, '', confirmation], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, UCI_STATE: uciState }
  });
  return readFile(join(state, 'job'), 'utf8');
}

test.before(async () => {
  await mkdir(bin, { recursive: true });
  await mkdir(uciState, { recursive: true });
  await writeFile(psl, 'com\nco.uk\npublic.example.test\n');
  await executable(join(bin, 'uci'), `#!/bin/sh
[ "$1" = -q ] && shift
command=$1; shift
case "$command" in
  get) cat "$UCI_STATE/$1" 2>/dev/null ;;
  add_list) key=\${1%%=*}; value=\${1#*=}; printf '%s\\n' "$value" >> "$UCI_STATE/$key" ;;
  del_list) key=\${1%%=*}; value=\${1#*=}; grep -Fvx -- "$value" "$UCI_STATE/$key" > "$UCI_STATE/$key.next" 2>/dev/null || true; mv "$UCI_STATE/$key.next" "$UCI_STATE/$key" ;;
  commit) exit 0 ;;
esac
`);
  await executable(join(bin, 'timeout'), '#!/bin/sh\nshift\nexec "$@"\n');
  await executable(join(bin, 'chown'), '#!/bin/sh\nexit 0\n');
  await executable(join(bin, 'stat'), `#!/bin/sh
[ "$1" = -c ] || exit 1
format=$2
path=$3
case "$format" in
  %u) printf '0\\n' ;;
  %a)
    if [ -f "$(dirname "$path")/.insecure-state" ]; then
      printf '755\\n'
    elif [ -d "$path" ]; then
      printf '700\\n'
    else
      printf '600\\n'
    fi
    ;;
esac
`);
  await writeFile(common, `MONITOR_STATE=${state}
MONITOR_JOB=${state}/job
MONITOR_ACTIVITY=${state}/activity.tsv
MONITOR_STATUS=${state}/status
MONITOR_COUNT=${state}/activity.count
MONITOR_LOCK=${state}/monitor.lock
monitor_state_init() {
  mkdir -p "$MONITOR_STATE" || return 1
  chmod 0700 "$MONITOR_STATE" || return 1
  : > "$MONITOR_ACTIVITY"
  : > "$MONITOR_STATUS"
  : > "$MONITOR_COUNT"
  : > "$MONITOR_LOCK"
}
`);
  await executable(init, `#!/bin/sh
printf '%s\\n' "$1" >> "$UCI_STATE/init.log"
[ "$1" = dl ] && [ "\${SLOW_DL:-0}" = 1 ] && sleep 1
[ "$1" = dl ] && [ "\${FAIL_DL:-0}" = 1 ] && exit 1
exit 0
`);
  let source = await readFile('root/usr/libexec/adblock-fast-monitor-job', 'utf8');
  source = source
    .replace('. /usr/lib/adblock-fast-monitor/common.sh', `. ${common}`)
    .replace('PSL_FILE=/usr/share/publicsuffix/public_suffix_list.dat', `PSL_FILE=${psl}`)
    .replaceAll('/etc/init.d/adblock-fast', init);
  await writeFile(worker, source);
});

test.after(async () => {
  await rm(runtime, { recursive: true, force: true });
});

test('malicious and public-suffix domains do not mutate UCI or invoke lifecycle actions', async () => {
  await run('block', 'bad;domain', 'confirmed');
  let job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /result=invalid-domain/);
  assert.equal((await stat(join(state, 'job'))).mode & 0o777, 0o600);
  await run('block', 'public.example.test', 'confirmed');
  job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /result=public-suffix/);
  await assert.rejects(readFile(join(uciState, 'init.log'), 'utf8'), { code: 'ENOENT' });
});

test('rebuild operations need a second confirmation at the worker boundary', async () => {
  await run('block', 'ads.example.test');
  const job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /result=confirmation-required/);
  await assert.rejects(readFile(join(uciState, 'init.log'), 'utf8'), { code: 'ENOENT' });
});

test('duplicate rules are idempotent and a successful rebuild remains DNS-degraded', async () => {
  await run('block', 'ads.example.test', 'confirmed');
  let job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /state=degraded/);
  assert.match(job, /result=persisted-active-unknown/);
  assert.match(job, /active_dns=unknown/);
  await run('block', 'ads.example.test', 'confirmed');
  job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /result=noop/);
  const calls = await readFile(join(uciState, 'init.log'), 'utf8');
  assert.deepEqual(calls.trim().split('\n'), ['dl']);
});

test('rebuild failure preserves its rechecked UCI result and does not claim active DNS success', async () => {
  await execFileAsync('sh', [worker, 'block', 'fail.example.test', '', 'confirmed'], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, UCI_STATE: uciState, FAIL_DL: '1' }
  });
  const job = await readFile(join(state, 'job'), 'utf8');
  assert.match(job, /state=failed/);
  assert.match(job, /result=rebuild-failed-active-unverified/);
  assert.match(job, /persisted=1/);
  assert.match(job, /active_dns=unknown/);
});

test('one lock prevents concurrent rebuilds', async () => {
  const before = await readFile(join(uciState, 'init.log'), 'utf8');
  const first = execFileAsync('sh', [worker, 'block', 'slow.example.test', '', 'confirmed'], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, UCI_STATE: uciState, SLOW_DL: '1' }
  });
  await new Promise(resolve => setTimeout(resolve, 100));
  await run('block', 'second.example.test', 'confirmed');
  const rejected = await readFile(join(state, 'job'), 'utf8');
  assert.match(rejected, /result=busy/);
  await first;
  const calls = await readFile(join(uciState, 'init.log'), 'utf8');
  assert.equal(calls.length - before.length, 3);
});

test('an insecure existing action state is rejected without changing job state', async () => {
  const before = await readFile(join(state, 'job'), 'utf8');
  await writeFile(join(state, '.insecure-state'), '1');
  await assert.rejects(run('allow', 'private.example.test'));
  assert.equal(await readFile(join(state, 'job'), 'utf8'), before);
  await rm(join(state, '.insecure-state'));
});
