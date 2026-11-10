// Minimal TAP test helpers for test/ucode/**/*.uc, loaded with
//   let t = require("testlib");
// (test/lib/ucode-runner and the suite runner put this directory on the
// module search path). Each failed assertion throws; t.test() catches it,
// prints "not ok", and continues. Call t.done() last: it prints the plan and
// exits non-zero if any test failed.
let count = 0, failed = 0;

function fmt(value) {
	return sprintf("%J", value);
}

function fail(message) {
	die(message);
}

return {
	test: function(name, fn) {
		count++;
		try {
			fn();
			print(`ok ${count} - ${name}\n`);
		}
		catch (e) {
			failed++;
			print(`not ok ${count} - ${name}\n`);
			for (let line in split(`${e.message ?? e}`, "\n"))
				print(`#   ${line}\n`);
		}
	},

	ok: function(value, message) {
		if (!value)
			fail(message ?? `expected truthy value, got ${fmt(value)}`);
	},

	// Deep equality via canonical JSON.
	eq: function(actual, expected, message) {
		if (fmt(actual) !== fmt(expected))
			fail(`${message ?? "values differ"}\nexpected: ${fmt(expected)}\nactual:   ${fmt(actual)}`);
	},

	match: function(string, regex, message) {
		if (type(string) != "string" || !match(string, regex))
			fail(`${message ?? "no match"}\npattern: ${regex}\nactual:  ${fmt(string)}`);
	},

	throws: function(fn, regex, message) {
		try {
			fn();
		}
		catch (e) {
			if (regex && !match(`${e.message ?? e}`, regex))
				fail(`${message ?? "wrong exception"}\npattern: ${regex}\nactual:  ${e.message ?? e}`);
			return;
		}
		fail(message ?? "expected an exception");
	},

	done: function() {
		print(`1..${count}\n`);
		if (failed) {
			print(`# ${failed} of ${count} failed\n`);
			exit(1);
		}
		exit(0);
	}
};
