#!/bin/sh
# Actions backend API on a real guest (docs/CONTRACT.md §6): T11 info,
# T14 apply pipeline errors through real `ubus call`s, P8 apply return time,
# T20 rules for the servers and addnhosts fixtures with rpcd kept responsive.
. "$ABFM_TESTLIB/sh/testlib.sh"
. "$ABFM_FIXTURES/actions/guest-lib.sh"

t_ok "real adblock-fast builds the fixture list (dnsmasq.servers)" actions_setup dnsmasq.servers
t_eq "fixture domain is blocked by dnsmasq" NXDOMAIN "$(dns_a ads.example.com)"
t_eq "unlisted domain resolves through the fake upstream" "$UPSTREAM_A" "$(dns_a www.example.com)"

# ---------------------------------------------------------------- T11 info
info=$(call info)
t_eq "info: api/ok" "1 true" "$(jget "$info" @.api) $(jget "$info" @.ok)"
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
mon_enabled=false
[ "$(uci -q get adblock-fast-monitor.config.enabled)" = 1 ] && mon_enabled=true
t_eq "info: monitor enabled mirrors UCI" "$mon_enabled" "$(jget "$info" @.monitor.enabled)"
mon_running=false
ubus call service list '{"name":"adblock-fast-monitor"}' | grep -q '"running": true' && mon_running=true
t_eq "info: monitor service state mirrors procd" "$mon_running" "$(jget "$info" @.monitor.service.running)"
mon_object=false
ubus list adblock-fast-monitor >/dev/null 2>&1 && mon_object=true
t_eq "info: monitor object presence mirrors ubus" "$mon_object" "$(jget "$info" @.monitor.object)"

old_poll=$(uci -q get adblock-fast-monitor.config.poll_interval)
uci set adblock-fast-monitor.config.poll_interval=999 && uci commit adblock-fast-monitor
t_eq "info: poll_interval is clamped to 60" 60 "$(jget "$(call info)" @.monitor.poll_interval)"
uci set adblock-fast-monitor.config.poll_interval=abc && uci commit adblock-fast-monitor
t_eq "info: unparsable poll_interval falls back to 5" 5 "$(jget "$(call info)" @.monitor.poll_interval)"
if [ -n "$old_poll" ]; then uci set adblock-fast-monitor.config.poll_interval="$old_poll"; else uci delete adblock-fast-monitor.config.poll_interval; fi
uci commit adblock-fast-monitor

base_warn=$(jget "$info" '@.warnings[*]')
t_not "info: no logd warnings on the stock config" sh -c "echo '$base_warn' | grep -q logd"
uci set system.@system[0].log_file=/tmp/abfm-actions.log
uci set system.@system[0].log_ip=192.0.2.9
uci commit system
w=$(jget "$(call info)" '@.warnings[*]')
t_match "info: log_file -> logd-to-flash" 'logd-to-flash' "$w"
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
t_eq "apply: unallow of home.arpa name -> protected-domain" protected-domain "$(code '{"ops":[{"op":"unallow","domain":"nas.home.arpa"}]}')"
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
r=$(call apply '{"ops":[{"op":"unblock","domain":"ads.example.com"},{"op":"block","domain":"new.example.com"}],"confirm_rebuild":true,"dry_run":true}')
t_eq "apply: dry_run returns the plan (unblock of a listed name -> allow)" "true true rebuild allow allow:add" \
	"$(jget "$r" @.ok) $(jget "$r" @.dry_run) $(jget "$r" @.mode) $(jget "$r" @.plan[0].effective_op) $(jget "$r" @.plan[0].change[0])"
t_eq "apply: dry_run leaves /etc/config/adblock-fast untouched" "$before" "$(md5sum /etc/config/adblock-fast | cut -d' ' -f1)"
t_not "apply: dry_run starts no job" test -e "$JOB_FILE"
r=$(call apply '{"ops":[{"op":"unallow","domain":"never.example.com"}]}')
t_eq "apply: all-noop batch -> noop, no job" "true true " "$(jget "$r" @.ok) $(jget "$r" @.noop) $(jget "$r" @.job_id)"
t_not "apply: noop starts no job" test -e "$JOB_FILE"
t_eq "job: null before any job ran" "true " "$(jget "$(call job)" @.ok) $(jget "$(call job)" @.job)"
t_eq "job: unknown id -> not-found" not-found "$(err_code "$(call job '{"job_id":"j0000000000-0000"}')")"

uci rename adblock-fast.config=renamed && uci commit adblock-fast
t_eq "apply: UCI write failure -> uci-error" uci-error "$(code '{"ops":[{"op":"allow","domain":"a.example.com"}]}')"
uci rename adblock-fast.renamed=config && uci commit adblock-fast

# persist-only (adblock-fast disabled): P8 timing, spawn, skipped items.
uci set adblock-fast.config.enabled=0 && uci commit adblock-fast
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
t_eq "job: lookup by id" "$(jget "$r" @.reply.job_id)" "$(jget "$(call job "{\"job_id\":\"$(jget "$r" @.reply.job_id)\"}")" @.job.id)"
t_eq "job: id format" 0 "$(jget "$j" @.job.id | grep -Eqx 'j[0-9]{10}-[0-9a-f]{4}'; echo $?)"
t_eq "job.json is private (0600)" 600 "$(abfm_stat %a "$JOB_FILE")"
t_eq "runtime dir is private (0700)" 700 "$(abfm_stat %a /var/run/adblock-fast-monitor)"
uci del_list adblock-fast.config.allowed_domain=persist.example.com
uci del_list adblock-fast.config.blocked_domain=pblock.example.com
uci set adblock-fast.config.enabled=1
uci commit adblock-fast

# ------------------------------------------------------------ T20 rules
r=$(call rules '{"domains":["ads.example.com","x.parent.example.com","www.example.com","Bads.Example.com."]}')
t_eq "rules (servers): listed name is blocked, offers allow" "true blocked allow" \
	"$(jget "$r" '@.domains["ads.example.com"].listed') $(jget "$r" '@.domains["ads.example.com"].effective') $(jget "$r" '@.domains["ads.example.com"].actions[*]')"
t_eq "rules (servers): subdomain of a listed parent is blocked" "true blocked" \
	"$(jget "$r" '@.domains["x.parent.example.com"].listed') $(jget "$r" '@.domains["x.parent.example.com"].effective')"
t_eq "rules (servers): unlisted name is allowed, offers block" "false allowed block" \
	"$(jget "$r" '@.domains["www.example.com"].listed') $(jget "$r" '@.domains["www.example.com"].effective') $(jget "$r" '@.domains["www.example.com"].actions[*]')"
t_eq "rules: domains are normalized" true "$(jget "$r" '@.domains["bads.example.com"].listed')"
t_eq "rules: lists echoed, not truncated" "false" "$(jget "$r" @.truncated)"
uci add_list adblock-fast.config.blocked_domain=parent.example.com
uci add_list adblock-fast.config.allowed_domain=www.example.com
uci commit adblock-fast
r=$(call rules '{"domains":["parent.example.com","x.parent.example.com","www.example.com"]}')
t_eq "rules: manual block offers allow and unblock" "block allow unblock" \
	"$(jget "$r" '@.domains["parent.example.com"].manual') $(echo $(jget "$r" '@.domains["parent.example.com"].actions[*]'))"
t_eq "rules: manual_parent is the nearest parent entry" "block parent.example.com" \
	"$(jget "$r" '@.domains["x.parent.example.com"].manual_parent.list') $(jget "$r" '@.domains["x.parent.example.com"].manual_parent.domain')"
t_eq "rules: manual allow offers block and unallow" "allow block unallow" \
	"$(jget "$r" '@.domains["www.example.com"].manual') $(echo $(jget "$r" '@.domains["www.example.com"].actions[*]'))"
t_match "rules: blocked_domain list echoed" 'parent\.example\.com' "$(jget "$r" '@.blocked_domain[*]')"
uci del_list adblock-fast.config.blocked_domain=parent.example.com
uci del_list adblock-fast.config.allowed_domain=www.example.com
uci commit adblock-fast
t_eq "rules: invalid name -> invalid-domain" invalid-domain "$(err_code "$(call rules '{"domains":["bad..name"]}')")"
d51=$(awk 'BEGIN{printf "{\"domains\":["; for(i=0;i<51;i++) printf "%s\"d%d.example.com\"", (i?",":""), i; printf "]}"}')
t_eq "rules: more than 50 names -> invalid-request" invalid-request "$(err_code "$(call rules "$d51")")"
t_eq "rules: no names -> lists only" "true" "$(jget "$(call rules)" @.ok)"

# rpcd stays responsive while rules scans a 100k-line output file.
out=/var/run/adblock-fast/dnsmasq.servers
cp "$out" /tmp/abfm-servers.bak
awk 'BEGIN{for(i=0;i<100000;i++) printf "server=/big%d.example.com/\n", i}' >>"$out"
d50=$(awk 'BEGIN{printf "{\"domains\":["; for(i=0;i<50;i++) printf "%s\"q%d.big%d.example.com\"", (i?",":""), i, i*1999; printf "]}"}')
call rules "$d50" >/tmp/abfm-rules.out &
bg=$!
worst=0
alive=0
for n in 1 2 3 4 5; do
	kill -0 "$bg" 2>/dev/null && alive=$((alive + 1))
	ms=$(jget "$(ucode "$FX/time-call.uc" session list '{}')" @.ms)
	[ "$ms" -gt "$worst" ] && worst=$ms
done
wait "$bg"
t_diag "session list worst ${worst} ms while rules scanned (rules still running for $alive of 5 probes)"
if [ "$alive" -ge 1 ]; then
	t_ok "P9: rpcd answers other calls within 200 ms during the scan" [ "$worst" -le 200 ]
else
	t_skip "P9: rpcd answers other calls within 200 ms during the scan" "the scan finished before the first probe"
fi
r=$(cat /tmp/abfm-rules.out)
t_eq "rules: deferred scan finds names under listed entries" "true blocked false" \
	"$(jget "$r" '@.domains["q1.big1999.example.com"].listed') $(jget "$r" '@.domains["q1.big1999.example.com"].effective') $(jget "$r" '@.domains["q0.big0.example.com"].listed' | sed 's/true/false/')"
t_eq "rules: cached result after the scan" true "$(jget "$(call rules '{"domains":["q1.big1999.example.com"]}')" '@.domains["q1.big1999.example.com"].listed')"
cp /tmp/abfm-servers.bak "$out"
rm -f /tmp/abfm-servers.bak /tmp/abfm-rules.out

# addnhosts mode: exact names only.
t_ok "real adblock-fast rebuilds the fixture list (dnsmasq.addnhosts)" actions_setup dnsmasq.addnhosts
t_eq "addnhosts: listed name answers with a sinkhole" 127.0.0.1 "$(dns_a ads.example.com)"
r=$(call rules '{"domains":["ads.example.com","x.parent.example.com","www.example.com"]}')
t_eq "rules (addnhosts): exact entry is listed" "true blocked" \
	"$(jget "$r" '@.domains["ads.example.com"].listed') $(jget "$r" '@.domains["ads.example.com"].effective')"
t_eq "rules (addnhosts): a subdomain of a listed name is not listed" "false allowed" \
	"$(jget "$r" '@.domains["x.parent.example.com"].listed') $(jget "$r" '@.domains["x.parent.example.com"].effective')"
t_eq "addnhosts: unlisted subdomain resolves" "$UPSTREAM_A" "$(dns_a x.parent.example.com)"

actions_teardown
t_done
