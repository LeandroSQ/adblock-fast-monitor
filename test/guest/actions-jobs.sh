#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Actions jobs on a real guest with real adblock-fast (docs/CONTRACT.md §7):
# T15 allow of a listed name, T16 no collateral, T17 block, allow of a manual
# block and block of a manual allow each run one rebuild with the full state
# sequence, T18 list server down, T19 busy, waiting for another adblock-fast
# run, kill -9 -> interrupted, start-timeout, lock-failed; verification in
# servers, conf, addnhosts and nftset modes and its reasons.
. "$ABFM_TESTLIB/sh/testlib.sh"
. "$ABFM_FIXTURES/actions/guest-lib.sh"

states() { echo $(jget "$1" '@.states[*]'); }
item() { jget "$1" "@.job.items[$2].$3"; }

t_ok "real adblock-fast builds the fixture list (dnsmasq.servers)" actions_setup dnsmasq.servers

# ------------------------------------------------ T15 allow of a listed name
t_eq "T15: tracker.example.com is blocked before" NXDOMAIN "$(dns_a tracker.example.com)"
m=$(log_mark)
w=$(watch '{"ops":[{"op":"allow","domain":"tracker.example.com"}],"confirm_rebuild":true}')
t_eq "T15: apply queued a rebuild" "true queued rebuild" \
	"$(jget "$w" @.apply.ok) $(jget "$w" @.apply.state) $(jget "$w" @.apply.mode)"
t_ok "P8: apply returned within 200 ms ($(jget "$w" @.apply_ms) ms)" [ "$(jget "$w" @.apply_ms)" -le 200 ]
t_eq "T15: state sequence" "queued applying verifying applied" "$(states "$w")"
t_eq "T15: item verified against the real answer" "ok allowed $UPSTREAM_A" \
	"$(item "$w" 0 result) $(item "$w" 0 observed) $(item "$w" 0 answer.a[0])"
t_eq "T15: job fields" "true statusSuccess verify" \
	"$(jget "$w" @.job.persisted) $(jget "$w" @.job.adblock_fast_status) $(jget "$w" @.job.phase)"
t_ok "T15: allowed_domain persisted" uci_has allowed_domain tracker.example.com
t_eq "T15: exactly one dnsmasq restart" 1 "$(dnsmasq_starts "$m")"
t_eq "T15: exactly one adblock-fast run" 1 "$(af_runs "$m")"
t_eq "T15: DNS answer flipped" "$UPSTREAM_A" "$(dns_a tracker.example.com)"
t_ok "job lock is free after the job" lock_free

# adblock-fast leaves unsaved UCI deltas while and after it runs; only its
# file_url size bookkeeping may appear for adblock-fast, so pending-uci-changes
# must not trigger right after a job.
deltas=$(jget "$w" '@.af_delta[*]')
t_match "adblock-fast wrote its size bookkeeping to /tmp/.uci during the job" "size='[0-9]+'" "$deltas"
t_eq "every adblock-fast delta seen during the job is size bookkeeping" "" \
	"$(printf '%s\n' "$deltas" | grep -v "^adblock-fast\.[^.]*\.size='[0-9]*'\$" | grep .)"
t_diag "/tmp/.uci/adblock-fast after the job: $(tr '\n' ' ' </tmp/.uci/adblock-fast 2>/dev/null)"
t_eq "info: no pending UCI changes right after the job" false "$(jget "$(call info)" @.adblock_fast.pending_uci_changes)"
r=$(call apply '{"ops":[{"op":"block","domain":"next.example.com"}],"confirm_rebuild":true,"dry_run":true}')
t_eq "apply right after the job is not refused as pending-uci-changes" "true " "$(jget "$r" @.ok) $(err_code "$r")"

# -------------------------------------- T16 no collateral (contract §14.1)
t_eq "T16: bads.example.com is blocked before" NXDOMAIN "$(dns_a bads.example.com)"
w=$(watch '{"ops":[{"op":"allow","domain":"ads.example.com"}],"confirm_rebuild":true}')
t_eq "T16: allow ads.example.com applied" "applied ok" "$(jget "$w" @.job.state) $(item "$w" 0 result)"
t_eq "T16: ads.example.com resolves" "$UPSTREAM_A" "$(dns_a ads.example.com)"
t_eq "T16: bads.example.com stays blocked" NXDOMAIN "$(dns_a bads.example.com)"
t_ok "T16: the output file still blocks bads.example.com" grep -qx 'server=/bads.example.com/' /var/run/adblock-fast/dnsmasq.servers

# ------------------- T17 block, allow of a block, block of an allow: one rebuild each
m=$(log_mark)
w=$(watch '{"ops":[{"op":"block","domain":"new.example.com"}],"confirm_rebuild":true}')
t_eq "T17 block: state sequence" "queued applying verifying applied" "$(states "$w")"
t_eq "T17 block: verified blocked" "block ok blocked NXDOMAIN" \
	"$(item "$w" 0 op) $(item "$w" 0 result) $(item "$w" 0 observed) $(item "$w" 0 answer.rcode)"
t_eq "T17 block: one adblock-fast run" 1 "$(af_runs "$m")"
t_ok "T17 block: blocked_domain persisted" uci_has blocked_domain new.example.com
t_eq "T17 block: DNS blocked" NXDOMAIN "$(dns_a new.example.com)"

m=$(log_mark)
w=$(watch '{"ops":[{"op":"allow","domain":"new.example.com"}],"confirm_rebuild":true}')
t_eq "T17 allow of a manual block: state sequence" "queued applying verifying applied" "$(states "$w")"
t_eq "T17 allow of a manual block: block removed, allow added, verified" "allow allow:add block:remove ok allowed" \
	"$(item "$w" 0 op) $(item "$w" 0 change[0]) $(item "$w" 0 change[1]) $(item "$w" 0 result) $(item "$w" 0 observed)"
t_eq "T17 allow of a manual block: one adblock-fast run" 1 "$(af_runs "$m")"
t_not "T17 allow of a manual block: blocked_domain entry removed" uci_has blocked_domain new.example.com
t_ok "T17 allow of a manual block: allowed_domain entry added" uci_has allowed_domain new.example.com
t_eq "T17 allow of a manual block: DNS allowed" "$UPSTREAM_A" "$(dns_a new.example.com)"

m=$(log_mark)
w=$(watch '{"ops":[{"op":"block","domain":"ads.example.com"}],"confirm_rebuild":true}')
t_eq "T17 block of a manual allow: state sequence" "queued applying verifying applied" "$(states "$w")"
t_eq "T17 block of a manual allow: allow removed, block added, verified" "allow:remove block:add blocked ok blocked" \
	"$(item "$w" 0 change[0]) $(item "$w" 0 change[1]) $(item "$w" 0 expect) $(item "$w" 0 result) $(item "$w" 0 observed)"
t_eq "T17 block of a manual allow: one adblock-fast run" 1 "$(af_runs "$m")"
t_not "T17 block of a manual allow: allowed_domain entry removed" uci_has allowed_domain ads.example.com
t_eq "T17 block of a manual allow: DNS blocked again" NXDOMAIN "$(dns_a ads.example.com)"

# --------------------------------------------- T18 list server down
uci set adblock-fast.fixture.url='http://10.0.2.2:1/abfm-list-server-down.txt'
uci commit adblock-fast
w=$(watch '{"ops":[{"op":"block","domain":"down.example.com"}],"confirm_rebuild":true}')
t_eq "T18: list server down -> failed/rebuild-failed, persisted" "failed rebuild-failed true" \
	"$(jget "$w" @.job.state) $(jget "$w" @.job.error.code) $(jget "$w" @.job.persisted)"
t_match "T18: error names adblock-fast's download error" 'errorDownloadingList' "$(jget "$w" @.job.error.message)"
t_eq "T18: adblock-fast itself reported statusSuccess (errors only)" statusSuccess "$(jget "$w" @.job.adblock_fast_status)"
t_eq "T18: items are not verified" unverified "$(item "$w" 0 result)"
t_ok "T18: UCI keeps the change (no rollback)" uci_has blocked_domain down.example.com
t_ok "T18: lock is free after a failed job" lock_free
uci set adblock-fast.fixture.url="$ABFM_FIXTURE_URL/actions/block.txt"
uci commit adblock-fast
w=$(watch '{"ops":[],"rebuild":true,"confirm_rebuild":true}')
t_eq "T18: 'Run rebuild' (ops:[], rebuild) recovers" "true rebuild applied" \
	"$(jget "$w" @.apply.ok) $(jget "$w" @.job.mode) $(jget "$w" @.job.state)"
t_eq "T18: persisted rule is effective after the rebuild" NXDOMAIN "$(dns_a down.example.com)"
t_eq "T18: list entries are back" NXDOMAIN "$(dns_a ads.example.com)"

# ------------------------------------------- T19 busy and interruption
hold_lock 20 &
holder=$!
t_ok "T19: test holds the job lock" abfm_wait_until 5 sh -c "! flock -n $LOCK_FILE true"
r=$(call apply '{"ops":[{"op":"block","domain":"busy.example.com"}],"confirm_rebuild":true}')
t_eq "T19: lock held -> busy" busy "$(err_code "$r")"
t_not "T19: busy wrote nothing" uci_has blocked_domain busy.example.com
kill "$holder"
wait "$holder" 2>/dev/null
t_ok "T19: lock released by the test" abfm_wait_until 5 lock_free

# A process that looks like another adblock-fast CLI run holds the job in
# `applying` before it runs `dl` (§7.2), which makes kill -9 deterministic.
fake_af_run 300 &
fake=$!
t_ok "T19: a fake adblock-fast run is visible" abfm_wait_until 5 pgrep -f /lib/adblock-fast/cli.uc
m=$(log_mark)
r=$(call apply '{"ops":[{"op":"block","domain":"slow.example.com"}],"confirm_rebuild":true}')
id=$(jget "$r" @.job_id)
r2=$(call apply '{"ops":[{"op":"block","domain":"other.example.com"}],"confirm_rebuild":true}')
t_eq "T19: second apply while the first is queued/running -> busy with its job_id" "busy $id" "$(err_code "$r2") $(jget "$r2" @.job_id)"
t_ok "T19: job reaches applying" abfm_wait_until 30 sh -c "jsonfilter -i $JOB_FILE -e @.state | grep -qx applying"
jpid=$(pgrep -f "job.uc $id")
t_ok "T19: job process found" [ -n "$jpid" ]
t_eq "T19: the job holds no rpcd sockets or pipes" 0 "$(ls -l "/proc/$jpid/fd" 2>/dev/null | grep -c 'socket:\|pipe:')"
t_not "T19: lock is held while the job runs" lock_free
r3=$(call apply '{"ops":[{"op":"block","domain":"other.example.com"}],"confirm_rebuild":true}')
t_eq "T19: apply during the job -> busy" busy "$(err_code "$r3")"
t_eq "T19: while another adblock-fast run is alive the job waits (phase rebuild, no run of its own)" "applying rebuild 0" \
	"$(jsonfilter -i "$JOB_FILE" -e @.state) $(jsonfilter -i "$JOB_FILE" -e @.phase) $(af_runs "$m")"
kill -9 "$jpid"
t_ok "T19: the killed job is gone" abfm_wait_until 5 sh -c "! kill -0 $jpid 2>/dev/null"
t_ok "T19: lock is free after kill -9" lock_free
j=$(call job "{\"job_id\":\"$id\"}")
t_eq "T19: killed job -> failed/interrupted" "failed interrupted" "$(jget "$j" @.job.state) $(jget "$j" @.job.error.code)"
t_eq "T19: interruption is persisted" failed "$(jsonfilter -i "$JOB_FILE" -e @.state)"

m=$(log_mark)
r=$(call apply '{"ops":[{"op":"allow","domain":"slow.example.com"}],"confirm_rebuild":true}')
id=$(jget "$r" @.job_id)
t_eq "T19: next apply accepted" "true queued" "$(jget "$r" @.ok) $(jget "$r" @.state)"
t_ok "T19: it waits in applying while the other run lives" abfm_wait_until 30 sh -c "jsonfilter -i $JOB_FILE -e @.phase | grep -qx rebuild"
t_eq "T19: no adblock-fast run of its own yet" 0 "$(af_runs "$m")"
kill "$fake"
wait "$fake" 2>/dev/null
j=$(wait_job_terminal 600)
t_eq "T19: once the other run ended, the job ran dl and completed" "$id applied 1" "$(jget "$j" @.job.id) $(jget "$j" @.job.state) $(af_runs "$m")"
t_eq "T19: no adblock-fast run left behind" "" "$(pgrep -f /lib/adblock-fast/cli.uc)"

# start-timeout: a queued job whose process never started.
ucode -e '
	let fs = require("fs");
	let j = json(fs.readfile(ARGV[0]));
	j.id = "j" + (time() - 60) + "-beef"; j.state = "queued"; j.created_at = time() - 60;
	j.started_at = null; j.finished_at = null; j.error = null;
	fs.writefile(ARGV[0], sprintf("%J", j));
' "$JOB_FILE"
j=$(call job)
t_eq "start-timeout: queued for 30 s without a job -> failed" "failed start-timeout" "$(jget "$j" @.job.state) $(jget "$j" @.job.error.code)"
/usr/libexec/adblock-fast-monitor/job.uc "$(jget "$j" @.job.id)"
t_eq "a stale job process does nothing" failed "$(jsonfilter -i "$JOB_FILE" -e @.state)"

# lock-failed: the job retries the lock for 10 s, then gives up (§7.2 step 1).
hold_lock 30 &
holder=$!
t_ok "lock-failed: test holds the job lock" abfm_wait_until 5 sh -c "! flock -n $LOCK_FILE true"
lid="j$(date +%s)-1f1f"
ucode -e '
	let fs = require("fs");
	fs.writefile(ARGV[0], sprintf("%J", { id: ARGV[1], state: "queued", mode: "rebuild", phase: null,
		created_at: time(), started_at: null, finished_at: null, persisted: true, adblock_fast_status: null,
		error: null, items: [ { op: "block", domain: "lf.example.com", change: [ "block:add" ], expect: "blocked",
			result: "pending", observed: null, answer: null, reason: null } ] }));
' "$JOB_FILE" "$lid"
/usr/libexec/adblock-fast-monitor/job.uc "$lid"
t_eq "lock-failed: job.uc exits 1" 1 "$?"
kill "$holder"
wait "$holder" 2>/dev/null
j=$(call job "{\"job_id\":\"$lid\"}")
t_eq "lock-failed: failed/lock-failed, items unverified" "failed lock-failed unverified" \
	"$(jget "$j" @.job.state) $(jget "$j" @.job.error.code) $(jget "$j" @.job.items[0].result)"
rm -f "$JOB_FILE"

# ---------------------------------------------- verification reasons
# dns-error: the fake upstream only knows example.com, so a forwarded
# example.net name comes back as an error (§7.1 `dns-error`).
w=$(watch '{"ops":[{"op":"allow","domain":"svc.example.net"},{"op":"block","domain":"nb.example.com"}],"confirm_rebuild":true}')
t_eq "servers mode: an upstream REFUSED -> partial" partial "$(jget "$w" @.job.state)"
t_eq "servers mode: unverified with reason dns-error" "unverified unknown dns-error" \
	"$(item "$w" 0 result) $(item "$w" 0 observed) $(item "$w" 0 reason)"
t_match "servers mode: the answer is the upstream error" '^(REFUSED|SERVFAIL)$' "$(item "$w" 0 answer.rcode)"
t_eq "servers mode: the other item is verified blocked" "ok blocked" "$(item "$w" 1 result) $(item "$w" 1 observed)"

t_ok "real adblock-fast builds the fixture list (dnsmasq.conf)" actions_setup dnsmasq.conf
w=$(watch '{"ops":[{"op":"allow","domain":"x.parent.example.com"},{"op":"allow","domain":"telemetry.example.com"}],"confirm_rebuild":true}')
t_eq "conf mode: allowing under a listed parent -> partial" partial "$(jget "$w" @.job.state)"
t_eq "conf mode: mismatch reason parent-blocked" "mismatch blocked parent-blocked" \
	"$(item "$w" 0 result) $(item "$w" 0 observed) $(item "$w" 0 reason)"
t_eq "conf mode: exact listed name is allowed" "ok allowed" "$(item "$w" 1 result) $(item "$w" 1 observed)"

# addnhosts: exact names only; a sinkhole answer is `blocked`.
t_ok "real adblock-fast builds the fixture list (dnsmasq.addnhosts)" actions_setup dnsmasq.addnhosts
w=$(watch '{"ops":[{"op":"block","domain":"ah.example.com"},{"op":"allow","domain":"tracker.example.com"}],"confirm_rebuild":true}')
t_eq "addnhosts mode: one rebuild job applied" "applied rebuild" "$(jget "$w" @.job.state) $(jget "$w" @.job.mode)"
t_eq "addnhosts mode: block verified by the sinkhole answer" "ok blocked 127.0.0.1" \
	"$(item "$w" 0 result) $(item "$w" 0 observed) $(item "$w" 0 answer.a[0])"
t_eq "addnhosts mode: allow of a listed name verified" "ok allowed $UPSTREAM_A" \
	"$(item "$w" 1 result) $(item "$w" 1 observed) $(item "$w" 1 answer.a[0])"
t_ok "addnhosts mode: the output file lists the new name" grep -qx '127.0.0.1 ah.example.com' /var/run/adblock-fast/dnsmasq.addnhosts

# nftset: the stock dnsmasq is built without nftset, so adblock-fast cannot
# build the list and the job says so (verification in this mode would be
# `dns-mode-unsupported`, unit-tested in plan.test.uc; ipset is the same).
uci set adblock-fast.config.dns=dnsmasq.nftset
uci commit adblock-fast
w=$(watch '{"ops":[{"op":"block","domain":"nf.example.com"}],"confirm_rebuild":true}')
t_eq "nftset mode: the apply is accepted and runs one rebuild" "true rebuild" "$(jget "$w" @.apply.ok) $(jget "$w" @.job.mode)"
t_eq "nftset mode: adblock-fast can't build the list without dnsmasq nftset support -> rebuild-failed, persisted" \
	"failed rebuild-failed true unverified" \
	"$(jget "$w" @.job.state) $(jget "$w" @.job.error.code) $(jget "$w" @.job.persisted) $(item "$w" 0 result)"
t_match "nftset mode: the error names adblock-fast's reason" 'errorNoDnsmasqNftset' "$(jget "$w" @.job.error.message)"

# ------------------------- adblock-fast's own `allow` (contract §10, §14.1)
# Recorded upstream behaviour that rules out using it for a fast path.
t_ok "real adblock-fast rebuilds the fixture list (dnsmasq.servers)" actions_setup dnsmasq.servers
$AF allow ads.example.com >/dev/null 2>&1
t_eq "upstream allow leaves the name blocked (server=/D/ is not removed)" NXDOMAIN "$(dns_a ads.example.com)"
t_ok "upstream allow keeps server=/D/" grep -qx 'server=/ads.example.com/' /var/run/adblock-fast/dnsmasq.servers
t_eq "upstream allow deletes a one-char-longer neighbour (collateral)" "$UPSTREAM_A" "$(dns_a bads.example.com)"
t_eq "upstream allow clears the service status" "" "$(af_status)"

actions_teardown
t_done
