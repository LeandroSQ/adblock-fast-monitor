#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Regenerates test/fixtures/logread/differential/*.expected.json: the
# per-key decisions of the ucode data plane (abfm.logparse + abfm.stats)
# over the captured dnsmasq fixtures, which test/unit/querylog-differential
# compares with querylog.js. One-time oracle: this stops working once the
# ucode modules are deleted; the committed outputs remain.
#
#   scripts/hosttools/querylog-differential.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out=test/fixtures/logread/differential
mkdir -p "$out"
for f in test/fixtures/dnsmasq/{servers,addnhosts,restart-heartbeat}.log \
	test/fixtures/logread/{servers,addnhosts,restart,logd-before,logd-after}.json; do
	name="$(basename "$f")"
	name="${name%.*}"
	case "$f" in *.log) name="dnsmasq-$name" ;; *) name="logread-$name" ;; esac
	test/lib/ucode-runner scripts/hosttools/querylog-differential.uc "/src/$f" >"$out/$name.expected.json"
	echo "$out/$name.expected.json"
done
