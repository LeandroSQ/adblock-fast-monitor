'use strict';

let fs = require('fs');
/* Direct-script invocation omits the script path from ARGV on stock ucode. */
let path = ARGV[0];
let expected_type = ARGV[1];
let expected_mode = +ARGV[2];
let metadata;

if (!path || !expected_type || !expected_mode)
	exit(64);

try {
	metadata = fs.lstat(path);
} catch (error) {
	exit(1);
}

if (!metadata)
	exit(3);

/* lstat deliberately rejects links instead of following them. Exact modes
 * keep monitor state root-only rather than silently repairing unsafe files. */
if (metadata.type != expected_type || metadata.uid != 0 ||
	metadata.mode != expected_mode)
	exit(1);

print('ok\n');
