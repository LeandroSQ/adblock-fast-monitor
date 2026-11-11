#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# shellcheck disable=SC2016 # single-quoted commands are expanded by the guest shell
# docs/CONTRACT.md §8.1 bound: `log read` with lines ≤ 900 stays under the
# 1 MiB ubus message cap even when every entry is a ~1000-byte line, so the
# page's first fetch can never knock logd off ubus. Ring set to 1 MiB
# (log_size=1024) for the test, restored afterwards.
set -u
. test/lib/sh/testlib.sh

orig="$(guest_exec 'uci -q get system.@system[0].log_size' || true)"
restore() {
	if [[ -n "$orig" ]]; then guest_exec "uci set system.@system[0].log_size='$orig'"; else guest_exec 'uci -q delete system.@system[0].log_size'; fi
	guest_exec 'uci commit system; /etc/init.d/log restart; ubus -t 15 wait_for log' >/dev/null 2>&1
}
trap restore EXIT
guest_exec "uci set system.@system[0].log_size=1024; uci commit system; /etc/init.d/log restart; ubus -t 15 wait_for log" >/dev/null
t_match 'T10: logd runs with a 1 MiB ring' ' -S 1024( |$)' "$(guest_exec 'tr "\0" " " </proc/$(pidof logd)/cmdline')"

guest_exec 'line=$(head -c 990 /dev/zero | tr "\0" x); i=0; while [ $i -lt 1000 ]; do logger -t abfm-big "$i $line"; i=$((i + 1)); done'

# root session through uhttpd, as the browser calls it
sid="$(curl --silent --max-time 30 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' --data \
	"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"00000000000000000000000000000000\",\"session\",\"login\",{\"username\":\"root\",\"password\":\"$GUEST_ROOT_PASSWORD\"}]}" |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][1]["ubus_rpc_session"])')"
reply="$GUEST_RUN_DIR/logd-oversize.json"
curl --silent --max-time 60 "$GUEST_HTTP_URL/ubus" -H 'Content-Type: application/json' --output "$reply" \
	--data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$sid\",\"log\",\"read\",{\"lines\":900,\"stream\":false,\"oneshot\":true}]}"
summary="$(python3 - "$reply" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
log = d["result"][1]["log"]
big = [e for e in log if "abfm-big" in e["msg"]]
print(d["result"][0], len(log), len(big), min(len(e["msg"]) for e in big), os.path.getsize(sys.argv[1]))
PY
)"
read -r status entries big minlen bytes <<<"$summary"
t_diag "log read lines:900 -> status $status, $entries entries ($big of ~1000 bytes, shortest $minlen), reply $bytes bytes"
t_eq 'T10: log read lines:900 succeeds through /ubus' '0 900' "$status $entries"
t_ok 'T10: the reply is made of ~1000-byte entries' test "$big" -ge 890 -a "$minlen" -ge 990
t_ok 'T10: the reply is below the 1 MiB ubus cap' test "$bytes" -lt 1048576
t_eq 'T10: the ubus CLI gets the same 900 entries' 900 \
	"$(guest_exec "ubus call log read '{\"lines\":900,\"stream\":false,\"oneshot\":true}' | jsonfilter -e '@.log[*].id' | wc -l")"
t_ok 'T10: logd is still registered on ubus' guest_exec 'ubus list log'
rm -f "$reply"
t_done
