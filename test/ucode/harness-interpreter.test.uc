// Proves test:ucode runs the interpreter OpenWrt 25.12.6 ships (ucode
// 85922056 + OpenWrt patches), not a newer or mocked one.
let t = require("testlib");
let fs = require("fs");

t.test("modules used by the package load", () => {
	for (let name in [ "fs", "io", "uloop", "struct", "ubus", "uci" ])
		t.ok(require(name), `require("${name}")`);
});

t.test("fs.lstat reports type and permission bits", () => {
	let st = fs.lstat("/tmp");
	t.eq(st.type, "directory");
	t.eq(st.mode & 4095, 1023, "tmpfs /tmp is 1777");
});

t.test("pinned uloop.process rejects a function executable (review B1)", () => {
	let uloop = require("uloop");
	uloop.init();
	t.eq(uloop.process(function() {}, [], {}, function() {}), null);
	t.match(uloop.error(), /Invalid argument/);
	t.ok(uloop.process("/bin/true", [], {}, function() {}), "string executable is accepted");
});

t.done();
