#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

MONITOR_CONFIG=adblock-fast-monitor
MONITOR_STATE="${ADBLOCK_FAST_MONITOR_STATE:-/tmp/adblock-fast-monitor}"
MONITOR_RUNTIME="${ADBLOCK_FAST_MONITOR_RUNTIME:-/var/run/adblock-fast-monitor}"
MONITOR_ACTIVITY="$MONITOR_STATE/activity.tsv"
MONITOR_STATUS="$MONITOR_STATE/status"
MONITOR_JOB="$MONITOR_STATE/job"
MONITOR_COUNT="$MONITOR_STATE/activity.count"
MONITOR_GENERATION="$MONITOR_STATE/generation"
MONITOR_KNOWN_BLOCKED="$MONITOR_STATE/known-blocked.tsv"
MONITOR_DNS_OWNER="$MONITOR_RUNTIME/dnsmasq-logqueries.owner"
MONITOR_LOCK="$MONITOR_STATE/monitor.lock"
MONITOR_METADATA=/usr/libexec/adblock-fast-monitor-metadata.uc

monitor_metadata() {
	/usr/bin/ucode "$MONITOR_METADATA" "$1" "$2" "$3" >/dev/null
}

monitor_secure_dir() {
	monitor_metadata "$1" directory 448 && return 0
	[ "$?" = 3 ] || return 1
	umask 077
	mkdir -m 0700 "$1" || return 1
	monitor_metadata "$1" directory 448
}

monitor_secure_file() {
	monitor_metadata "$1" file 384 && return 0
	[ "$?" = 3 ] || return 1
	umask 077
	: >"$1" || return 1
	monitor_metadata "$1" file 384
}

monitor_state_init() {
	umask 077
	monitor_secure_dir "$MONITOR_RUNTIME" || return 1
	monitor_secure_dir "$MONITOR_STATE" || return 1
	monitor_secure_file "$MONITOR_ACTIVITY" || return 1
	monitor_secure_file "$MONITOR_STATUS" || return 1
	monitor_secure_file "$MONITOR_COUNT" || return 1
	monitor_secure_file "$MONITOR_GENERATION" || return 1
	monitor_secure_file "$MONITOR_KNOWN_BLOCKED" || return 1
	monitor_secure_file "$MONITOR_LOCK" || return 1
	[ -s "$MONITOR_STATUS" ] || {
		printf '%s\n' state=disabled started=0 allowed=0 blocked=0 unknown=0 lost=0 capacity=0 generation=0 >"$MONITOR_STATUS"
		chmod 0600 "$MONITOR_STATUS"
	}
	[ -s "$MONITOR_COUNT" ] || printf '%s\n' 0 >"$MONITOR_COUNT"
	[ -s "$MONITOR_GENERATION" ] || printf '%s\n' 0 >"$MONITOR_GENERATION"
}

monitor_refresh_known_blocks() {
	local tmp count domain
	tmp="$MONITOR_STATE/.known-blocked.$$"
	count=0
	umask 077
	# This bounded, startup-only index identifies explicit adblock-fast rules.
	# Downloaded lists are deliberately not scanned on the DNS hot path.
	uci -q get adblock-fast.config.blocked_domain 2>/dev/null |
		tr ' ' '\n' |
		{
			while IFS= read -r domain; do
				case "$domain" in
					''|*[!A-Za-z0-9.-]*) continue ;;
				esac
				[ "$count" -lt 1024 ] || break
				printf '%s\n' "$domain"
				count=$((count + 1))
			done
		} >"$tmp" || { rm -f "$tmp"; return 1; }
	chown root:root "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$MONITOR_KNOWN_BLOCKED" ||
		{ rm -f "$tmp"; return 1; }
	monitor_metadata "$MONITOR_KNOWN_BLOCKED" file 384
}

monitor_lock() {
	lock "$MONITOR_LOCK" 2>/dev/null
}

monitor_unlock() {
	lock -u "$MONITOR_LOCK" 2>/dev/null
}

monitor_get() {
	sed -n "s/^$1=//p" "$MONITOR_STATUS" 2>/dev/null | tail -n 1
}

monitor_set() {
	local key="$1" value="$2" tmp
	monitor_lock || return 1
	tmp="$MONITOR_STATE/.status.$$"
	umask 077
	grep -v "^${key}=" "$MONITOR_STATUS" >"$tmp" 2>/dev/null || true
	printf '%s=%s\n' "$key" "$value" >>"$tmp"
	chown root:root "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$MONITOR_STATUS"
	local result=$?
	monitor_unlock
	return "$result"
}

monitor_max_events() {
	local value
	value="$(uci -q get "$MONITOR_CONFIG.config.max_events")"
	case "$value" in *[!0-9]*|'') value=256 ;; esac
	[ "$value" -ge 32 ] 2>/dev/null && [ "$value" -le 1024 ] 2>/dev/null || value=256
	printf '%s\n' "$value"
}

monitor_dnsmasq_release() {
	local previous=__absent__ applied=1 current key value
	[ -f "$MONITOR_DNS_OWNER" ] || return 0
	monitor_metadata "$MONITOR_DNS_OWNER" file 384 || return 1
	while IFS='=' read -r key value; do
		case "$key" in
			previous) previous="$value" ;;
			applied) applied="$value" ;;
		esac
	done <"$MONITOR_DNS_OWNER"
	current="$(uci -q get dhcp.@dnsmasq[0].logqueries)"
	if [ "$current" = "$applied" ]; then
		if [ "$previous" = __absent__ ]; then
			uci -q delete dhcp.@dnsmasq[0].logqueries
		else
			uci -q set "dhcp.@dnsmasq[0].logqueries=$previous"
		fi
		uci -q commit dhcp
		/etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
	fi
	rm -f "$MONITOR_DNS_OWNER"
}

monitor_dnsmasq_acquire() {
	local current tmp
	current="$(uci -q get dhcp.@dnsmasq[0].logqueries)"
	[ -f "$MONITOR_DNS_OWNER" ] && return 0
	# A pre-existing enabled setting was not applied by this monitor.
	[ "$current" = 1 ] && return 0
	tmp="$MONITOR_RUNTIME/.dnsmasq-owner.$$"
	umask 077
	{
		printf 'applied=1\n'
		if [ -n "$current" ]; then printf 'previous=%s\n' "$current"; else printf 'previous=__absent__\n'; fi
	} >"$tmp" || return 1
	chown root:root "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$MONITOR_DNS_OWNER" || return 1
	monitor_metadata "$MONITOR_DNS_OWNER" file 384 || return 1
	uci -q set dhcp.@dnsmasq[0].logqueries=1
	uci -q commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
}
