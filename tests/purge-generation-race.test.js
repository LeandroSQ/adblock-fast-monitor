'use strict';

const assert = require('assert');
const fs = require('fs');

/*
 * Models the required publication invariant: a purge and a snapshot share one
 * critical section, so a snapshot that started before the purge cannot publish
 * retained events after the purge generation advances.
 */
let generation = 0;
let published = [ 'before.example' ];
let locked = false;

function withLock(fn) {
	assert.strictEqual(locked, false);
	locked = true;
	try {
		return fn();
	} finally {
		locked = false;
	}
}

function purge() {
	withLock(() => {
		generation++;
		published = [];
	});
}

function snapshot(events, observedGeneration) {
	return withLock(() => {
		if (observedGeneration !== generation)
			return false;
		published = events;
		return true;
	});
}

const oldGeneration = generation;
purge();
assert.strictEqual(snapshot([ 'before.example' ], oldGeneration), false);
assert.deepStrictEqual(published, []);

const ring = fs.readFileSync('root/usr/libexec/adblock-fast-monitor-ring.uc', 'utf8');
assert.match(ring, /fs\.flock\(lock_file, 'ex'\)/);
assert.match(ring, /reset_if_purged\(\);[\s\S]*atomic_write\(state_dir \+ '\/activity\.tsv'/);
assert.match(ring, /atomic_write\(state_dir \+ '\/status', status\)[\s\S]*fs\.flock\(lock_file, 'un'\)/);

console.log('purge generation concurrency regression passed');
