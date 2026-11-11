#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Actions backend API on a real guest (docs/CONTRACT.md §6): T11 info,
# T14 apply pipeline errors through real `ubus call`s, P8 apply return time,
# a LuCI session's staged UCI change is never committed by apply.
. "$ABFM_TESTLIB/sh/testlib.sh"
. "$ABFM_FIXTURES/actions/guest-lib.sh"

t_ok "real adblock-fast builds the fixture list (dnsmasq.servers)" actions_setup dnsmasq.servers
t_eq "fixture domain is blocked by dnsmasq" NXDOMAIN "$(dns_a ads.example.com)"
t_eq "unlisted domain resolves through the fake upstream" "$UPSTREAM_A" "$(dns_a www.example.com)"

# ---------------------------------------------------------------- T11 info
info=$(call info)
t_eq "info: api/ok" "2 true" "$(jget "$info" @.api) $(jget "$info" @.ok)"
t_eq "info: adblock_fast installed/enabled/status/dns" "true true statusSuccess dnsmasq.servers" \
	"$(jget "$info" @.adblock_fast.installed) $(jget "$info" @.adblock_fast.enabled) $(jget "$info" @.adblock_fast.status) $(jget "$info" @.adblock_fast.dns)"
t_eq "info: output file of the dns mode exists" "/var/run/adblock-fast/dnsmasq.servers true" \
	"$(jget "$info" @.adblock_fast.output_file) $(jget "$info" @.adblock_fast.output_exists)"
t_ok "adblock-fast's own unsaved file_url size bookkeeping is present" grep -q "size=" /tmp/.uci/adblock-fast
t_eq "info: no external config; size bookkeeping is not a pending change" "false false" \
	"$(jget "$info" @.adblock_fast.external_config) $(jget "$info" @.adblock_fast.pending_uci_changes)"
sec=$(uci show dhcp.@dnsmasq[0] | sed -n '1s/^dhcp\.\([^=]*\)=dnsmasq$/\1/p')
t_eq "info: dnsmasq running, instance section and default confdir" "true $sec /tmp/dnsmasq.$sec.d" \
	"$(jget "$info" @.dnsmasq.running) $(jget "$info" @.dnsmasq.instances[0].section) $(jget "$info" @.dnsmasq.instances[0].confdir)"
ql=false
[ "$(uci -q get adblock-fast-monitor.config.query_logging)" = 1 ] && ql=true
t_eq "info: query_logging mirrors UCI" "$ql" "$(jget "$info" @.monitor.query_logging)"
t_eq "info: monitor holds only query_logging" query_logging "$(ucode -e 'print(join(" ", sort(keys(json(ARGV[0]).monitor))))' "$info")"
t_eq "info: dnsmasq instances carry exactly the §6.1 fields" "confdir dropin logfacility_file running section uci_logqueries" \
	"$(echo $(ucode -e 'print(join("\n", sort(keys(json(ARGV[0]).dnsmasq.instances[0]))))' "$info"))"
host=$(uci -q get system.@system[0].hostname | tr 'A-Z' 'a-z')
t_eq "info: protected_suffixes = built-ins, heartbeat, dhcp domain, hostname" \
	"localhost arpa local internal invalid onion bind heartbeat.example.com lan $host" "$(echo $(jget "$info" '@.protected_suffixes[*]'))"
t_eq "info: local_domains are the dhcp domain/local values" "lan" "$(jget "$info" '@.local_domains[*]' | sort -u | tr '\n' ' ' | sed 's/ $//')"
cp /etc/config/dhcp /tmp/abfm-dhcp.bak
uci set dhcp.@dnsmasq[0].local=/corp.example/
uci set dhcp.@dnsmasq[0].domain=Home.Example
uci commit dhcp
t_eq "info: local_domains follow dhcp (lower-cased, slashes stripped)" "home.example corp.example" \
	"$(echo $(jget "$(call info)" '@.local_domains[*]'))"
cp /tmp/abfm-dhcp.bak /etc/config/dhcp && rm -f /tmp/abfm-dhcp.bak
logsize=$(uci -q get system.@system[0].log_buffer_size || uci -q get system.@system[0].log_size || echo 64)
t_eq "info: logd.size_kib is the ring size log.init uses" "$logsize" "$(jget "$info" @.logd.size_kib)"

base_warn=$(jget "$info" '@.warnings[*]')
t_not "info: no logd warnings on the stock config" sh -c "echo '$base_warn' | grep -q logd"
uci set system.@system[0].log_file=/tmp/abfm-actions.log
uci commit system
t_not "info: a log_file on tmpfs is not logd-to-flash" sh -c "echo '$(jget "$(call info)" '@.warnings[*]')' | grep -q logd-to-flash"
uci set system.@system[0].log_file=/root/abfm-actions.log
uci set system.@system[0].log_ip=192.0.2.9
uci commit system
w=$(jget "$(call info)" '@.warnings[*]')
t_match "info: log_file on flash -> logd-to-flash" 'logd-to-flash' "$w"
t_match "info: log_ip -> logd-remote" 'logd-remote' "$w"
uci delete system.@system[0].log_file
uci delete system.@system[0].log_ip
uci commit system

uci set dhcp.@dnsmasq[0].logfacility=/tmp/abfm-dnsmasq.log
uci set dhcp.@dnsmasq[0].logqueries=1
uci commit dhcp
i2=$(call info)
t_eq "info: logfacility with a path -> logfacility_file" true "$(jget "$i2" @.dnsmasq.instances[0].logfacility_file)"
t_eq "info: logqueries=1 -> uci_logqueries" true "$(jget "$i2" @.dnsmasq.instances[0].uci_logqueries)"
t_match "info: uci logqueries -> query-logging-active" 'query-logging-active' "$(jget "$i2" '@.warnings[*]')"
uci delete dhcp.@dnsmasq[0].logfacility
uci delete dhcp.@dnsmasq[0].logqueries
uci commit dhcp
dropin=/tmp/dnsmasq.$sec.d/adblock-fast-monitor.conf
had_dropin=0
[ -f "$dropin" ] && had_dropin=1
mkdir -p "/tmp/dnsmasq.$sec.d"
[ "$had_dropin" = 1 ] || echo 'log-queries=extra' >"$dropin"
i3=$(call info)
t_eq "info: drop-in file -> dropin" true "$(jget "$i3" @.dnsmasq.instances[0].dropin)"
t_match "info: drop-in -> query-logging-active" 'query-logging-active' "$(jget "$i3" '@.warnings[*]')"
[ "$had_dropin" = 1 ] || rm -f "$dropin"

# ------------------------------------------------------- T14 apply errors
code() { err_code "$(call apply "$1")"; }
t_eq "apply: non-object op -> invalid-request" invalid-request "$(code '{"ops":[42]}')"
t_eq "apply: unknown op -> invalid-request" invalid-request "$(code '{"ops":[{"op":"nuke","domain":"a.example.com"}]}')"
t_eq "apply: no ops -> batch-empty" batch-empty "$(code '{}')"
t_eq "apply: ops:[] -> batch-empty" batch-empty "$(code '{"ops":[]}')"
ops65=$(awk 'BEGIN{printf "{\"ops\":["; for(i=0;i<65;i++) printf "%s{\"op\":\"allow\",\"domain\":\"d%d.example.com\"}", (i?",":""), i; printf "]}"}')
t_eq "apply: 65 ops -> batch-too-large" batch-too-large "$(code "$ops65")"
r=$(call apply '{"ops":[{"op":"allow","domain":"ok.example.com"},{"op":"block","domain":"bad..example.com"}]}')
t_eq "apply: invalid-domain carries index and domain" "invalid-domain 1 bad..example.com" \
	"$(err_code "$r") $(jget "$r" @.error.index) $(jget "$r" @.error.domain)"
t_eq "apply: IPv4 literal -> invalid-domain" invalid-domain "$(code '{"ops":[{"op":"block","domain":"10.0.2.2"}]}')"
t_eq "apply: block of the heartbeat domain -> protected-domain" protected-domain "$(code '{"ops":[{"op":"block","domain":"Heartbeat.Example.com."}]}')"
t_eq "apply: block under the dhcp local domain -> protected-domain" protected-domain "$(code '{"ops":[{"op":"block","domain":"router.lan"}]}')"
t_eq "apply: block of home.arpa name -> protected-domain" protected-domain "$(code '{"ops":[{"op":"block","domain":"nas.home.arpa"}]}')"
t_eq "apply: v1 op unblock -> invalid-request" invalid-request "$(code '{"ops":[{"op":"unblock","domain":"a.example.com"}]}')"
t_eq "apply: v1 op unallow -> invalid-request" invalid-request "$(code '{"ops":[{"op":"unallow","domain":"a.example.com"}]}')"
t_eq "apply: block of the config_update_url host -> protected-domain" protected-domain "$(code '{"ops":[{"op":"block","domain":"cdn.jsdelivr.net"}]}')"
uci set adblock-fast.extra=file_url
uci set adblock-fast.extra.url='https://lists.example.org/hosts.txt'
uci set adblock-fast.extra.enabled=1
uci commit adblock-fast
t_eq "apply: block of an enabled file_url host -> protected-domain" protected-domain "$(code '{"ops":[{"op":"block","domain":"lists.example.org"}]}')"
uci delete adblock-fast.extra
uci commit adblock-fast
t_eq "apply: allow of the heartbeat domain is not protected (dry run)" true \
	"$(jget "$(call apply '{"ops":[{"op":"allow","domain":"heartbeat.example.com"}],"dry_run":true,"confirm_rebuild":true}')" @.ok)"
t_eq "apply: co.uk -> public-suffix" public-suffix "$(code '{"ops":[{"op":"allow","domain":"co.uk"}]}')"
t_eq "apply: github.io -> public-suffix" public-suffix "$(code '{"ops":[{"op":"block","domain":"github.io"}]}')"
t_eq "apply: allow and block of one name -> conflict" conflict \
	"$(code '{"ops":[{"op":"allow","domain":"a.example.com"},{"op":"block","domain":"A.example.com"}]}')"
uci add_list adblock-fast.config.allowed_domain=allowed.example.com
uci commit adblock-fast
r=$(call apply '{"ops":[{"op":"block","domain":"x.allowed.example.com"}],"confirm_rebuild":true}')
t_eq "apply: block under an allowed entry -> allow-overrides" "allow-overrides x.allowed.example.com" \
	"$(err_code "$r") $(jget "$r" @.error.domain)"
uci del_list adblock-fast.config.allowed_domain=allowed.example.com
uci commit adblock-fast

mv $AF $AF.abfm-test
t_eq "apply: no /etc/init.d/adblock-fast -> adblock-fast-missing" adblock-fast-missing "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
t_eq "info: installed=false without the init script" false "$(jget "$(call info)" @.adblock_fast.installed)"
mv $AF.abfm-test $AF
uci set adblock-fast.config.dnsmasq_config_file_url='https://lists.example.org/dnsmasq.conf'
uci commit adblock-fast
t_eq "apply: dnsmasq_config_file_url -> external-config" external-config "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
uci delete adblock-fast.config.dnsmasq_config_file_url
uci set adblock-fast.config.dns=smartdns.domainset
uci commit adblock-fast
t_eq "apply: smartdns mode -> unsupported-dns-mode" unsupported-dns-mode "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
uci set adblock-fast.config.dns=dnsmasq.servers
uci commit adblock-fast
uci set adblock-fast.config.verbosity=1
t_eq "info: unsaved adblock-fast changes -> pending_uci_changes" true "$(jget "$(call info)" @.adblock_fast.pending_uci_changes)"
t_eq "apply: unsaved adblock-fast changes -> pending-uci-changes" pending-uci-changes "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
uci revert adblock-fast

r=$(call apply '{"ops":[{"op":"block","domain":"new.example.com"}]}')
t_eq "apply: rebuild without confirm -> confirm-required with mode and plan" "confirm-required rebuild new.example.com block:add" \
	"$(err_code "$r") $(jget "$r" @.mode) $(jget "$r" @.plan[0].domain) $(jget "$r" @.plan[0].change[0])"

t_not "rpcd rejects a wrongly typed field before the plugin" ubus call luci.adblock-fast-monitor apply '{"ops":"x"}'
t_not "rpcd rejects an unknown field before the plugin" ubus call luci.adblock-fast-monitor apply '{"opz":[]}'

before=$(md5sum /etc/config/adblock-fast | cut -d' ' -f1)
r=$(call apply '{"ops":[{"op":"allow","domain":"ads.example.com"},{"op":"block","domain":"new.example.com"}],"confirm_rebuild":true,"dry_run":true}')
t_eq "apply: dry_run returns the plan (allow of a listed name)" "true true rebuild allow allow:add" \
	"$(jget "$r" @.ok) $(jget "$r" @.dry_run) $(jget "$r" @.mode) $(jget "$r" @.plan[0].op) $(jget "$r" @.plan[0].change[0])"
t_eq "apply: dry_run leaves /etc/config/adblock-fast untouched" "$before" "$(md5sum /etc/config/adblock-fast | cut -d' ' -f1)"
t_not "apply: dry_run starts no job" test -e "$JOB_FILE"
uci add_list adblock-fast.config.allowed_domain=never.example.com && uci commit adblock-fast
r=$(call apply '{"ops":[{"op":"allow","domain":"never.example.com"}]}')
uci del_list adblock-fast.config.allowed_domain=never.example.com && uci commit adblock-fast
t_eq "apply: all-noop batch -> noop, no job" "true true " "$(jget "$r" @.ok) $(jget "$r" @.noop) $(jget "$r" @.job_id)"
t_not "apply: noop starts no job" test -e "$JOB_FILE"
t_eq "job: null before any job ran" "true " "$(jget "$(call job)" @.ok) $(jget "$(call job)" @.job)"
t_eq "job: unknown id -> not-found" not-found "$(err_code "$(call job '{"job_id":"j0000000000-0000"}')")"

uci rename adblock-fast.config=renamed && uci commit adblock-fast
t_eq "apply: UCI write failure -> uci-error" uci-error "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
uci rename adblock-fast.renamed=config && uci commit adblock-fast

# persist-only (adblock-fast disabled): P8 timing, spawn, skipped items.
uci set adblock-fast.config.enabled=0 && uci commit adblock-fast
# A LuCI session stages enabled=1 for adblock-fast without applying it
# (rpcd keeps it in /var/run/rpcd/uci-<sid>). apply commits through its own
# savedir, so the staged change is neither used (the job stays persist-only)
# nor committed, and stays staged (§6.3 step 9, §14.9).
sid=$(jget "$(ubus call session create '{"timeout":300}')" @.ubus_rpc_session)
ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"uci\",\"objects\":[[\"adblock-fast\",\"read\"],[\"adblock-fast\",\"write\"]]}"
ubus call uci set "{\"ubus_rpc_session\":\"$sid\",\"config\":\"adblock-fast\",\"section\":\"config\",\"values\":{\"enabled\":\"1\"}}"
t_match "a LuCI session has a staged adblock-fast change" "enabled" \
	"$(ubus call uci changes "{\"ubus_rpc_session\":\"$sid\",\"config\":\"adblock-fast\"}")"
chmod -x /usr/libexec/adblock-fast-monitor/job.uc
r=$(call apply '{"ops":[{"op":"allow","domain":"spawn.example.com"}]}')
chmod +x /usr/libexec/adblock-fast-monitor/job.uc
t_eq "apply: job cannot be started -> spawn-failed, persisted" "spawn-failed true" "$(err_code "$r") $(jget "$r" @.persisted)"
t_ok "apply: spawn-failed still persisted the UCI change" uci_has allowed_domain spawn.example.com
uci del_list adblock-fast.config.allowed_domain=spawn.example.com && uci commit adblock-fast
rm -f "$JOB_FILE"
r=$(ucode "$FX/time-call.uc" luci.adblock-fast-monitor apply '{"ops":[{"op":"allow","domain":"persist.example.com"},{"op":"block","domain":"pblock.example.com"}]}')
ms=$(jget "$r" @.ms)
t_diag "apply (persist-only, UCI commit + spawn) returned in ${ms} ms"
t_ok "P8: apply returns within 200 ms" [ "$ms" -le 200 ]
t_eq "apply: adblock-fast disabled -> persist-only job queued" "true persist-only queued" \
	"$(jget "$r" @.reply.ok) $(jget "$r" @.reply.mode) $(jget "$r" @.reply.state)"
j=$(wait_job_terminal 60)
t_eq "persist-only job: applied with skipped items" "applied skipped skipped true" \
	"$(jget "$j" @.job.state) $(jget "$j" @.job.items[0].result) $(jget "$j" @.job.items[1].result) $(jget "$j" @.job.persisted)"
t_ok "persist-only: allowed_domain persisted" uci_has allowed_domain persist.example.com
t_ok "persist-only: blocked_domain persisted" uci_has blocked_domain pblock.example.com
t_eq "the session's staged enabled=1 was not committed" 0 "$(uci -q get adblock-fast.config.enabled)"
t_match "and is still staged in the session" "enabled" \
	"$(ubus call uci changes "{\"ubus_rpc_session\":\"$sid\",\"config\":\"adblock-fast\"}")"
ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}"
t_eq "job: lookup by id" "$(jget "$r" @.reply.job_id)" "$(jget "$(call job "{\"job_id\":\"$(jget "$r" @.reply.job_id)\"}")" @.job.id)"
t_eq "job: id format" 0 "$(jget "$j" @.job.id | grep -Eqx 'j[0-9]{10}-[0-9a-f]{4}'; echo $?)"
t_eq "job.json is private (0600)" 600 "$(abfm_stat %a "$JOB_FILE")"
t_eq "runtime dir is private (0700)" 700 "$(abfm_stat %a /var/run/adblock-fast-monitor)"
uci del_list adblock-fast.config.allowed_domain=persist.example.com
uci del_list adblock-fast.config.blocked_domain=pblock.example.com
uci set adblock-fast.config.enabled=1
uci commit adblock-fast

# addnhosts mode: exact names only (jobs in this mode: actions-jobs.sh).
t_ok "real adblock-fast rebuilds the fixture list (dnsmasq.addnhosts)" actions_setup dnsmasq.addnhosts
t_eq "addnhosts: listed name answers with a sinkhole" 127.0.0.1 "$(dns_a ads.example.com)"
t_eq "info (addnhosts): dns mode and output file" "dnsmasq.addnhosts /var/run/adblock-fast/dnsmasq.addnhosts true" \
	"$(i=$(call info); echo $(jget "$i" @.adblock_fast.dns) $(jget "$i" @.adblock_fast.output_file) $(jget "$i" @.adblock_fast.output_exists))"
t_eq "addnhosts: unlisted subdomain resolves" "$UPSTREAM_A" "$(dns_a x.parent.example.com)"

actions_teardown
t_done
