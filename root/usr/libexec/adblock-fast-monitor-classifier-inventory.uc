'use strict';

/* Capability gate: return nothing usable unless one dnsmasq procd instance
 * exposes one generated -C file and no un-inventoried include mechanism. */
let ubus = require('ubus');
let fs = require('fs');
let output = ARGV[0];
if (!output) exit(64);

let connection = ubus.connect();
if (!connection)
	exit(1);
let service = connection.call('service', 'list', { name: 'dnsmasq' });
connection.disconnect();
let instances = service?.dnsmasq?.instances;
if (!instances || length(keys(instances)) != 1)
	exit(2);
let name = keys(instances)[0];
let instance = instances[name];
let command = instance?.command;
if (type(instance?.pid) != 'number' || type(command) != 'array')
	exit(3);

let config = null;
for (let index = 0; index < length(command); index++) {
	if (command[index] == '-C' && index + 1 < length(command))
		config = command[index + 1];
	if (command[index] == '--conf-file' || command[index] == '--conf-dir' ||
		command[index] == '--addn-hosts' || command[index] == '--servers-file')
		exit(4);
}
if (!config || !fs.lstat(config) || fs.lstat(config).type != 'file')
	exit(5);

let contents = fs.readfile(config) || '';
for (let line in split(contents, '\n')) {
	if (line == 'servers-file=' + output)
		continue;
	if (match(line, /^(conf-file|conf-dir|addn-hosts|servers-file)=/))
		exit(6);
}
print(sprintf('%J', { instance: name, pid: instance.pid, config, output }) + '\n');
