# SPDX-License-Identifier: Apache-2.0
# Shared POSIX/BusyBox-ash test helpers for test/shell/*.sh (host userland
# container) and test/guest/*.sh (inside the OpenWrt guest). Only uses
# applets OpenWrt 25.12 enables by default; file metadata goes through ucode
# because BusyBox `stat` is disabled on stock images.
#
#   . "$ABFM_TESTLIB/sh/testlib.sh"
#   t_ok   "description" command [args...]      # pass if the command succeeds
#   t_not  "description" command [args...]      # pass if the command fails
#   t_eq   "description" expected actual
#   t_match "description" ERE string
#   t_skip "description" reason
#   t_diag message...                           # "# message" (TAP diagnostic)
#   t_done                                      # prints the plan; exit 1 on failure
#   abfm_stat FORMAT PATH        # lstat; FORMAT tokens: %u %g %a %s %F %Y %i
#   abfm_timeout SECONDS cmd...  # BusyBox-safe timeout (integer seconds); 124 on expiry
#   abfm_wait_until SECONDS cmd...  # poll cmd every 1 s until it succeeds
#   abfm_tmpdir                  # mktemp -d, removed by t_done

T_COUNT=0
T_FAILED=0
T_TMPDIRS=''

t__result() { # status description [diagnostic]
	T_COUNT=$((T_COUNT + 1))
	if [ "$1" -eq 0 ]; then
		printf 'ok %d - %s\n' "$T_COUNT" "$2"
	else
		T_FAILED=$((T_FAILED + 1))
		printf 'not ok %d - %s\n' "$T_COUNT" "$2"
		[ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/#   /'
	fi
}

t_ok() {
	_d=$1; shift
	if _out=$("$@" 2>&1); then t__result 0 "$_d"; else t__result 1 "$_d" "command failed: $* :: $_out"; fi
}

t_not() {
	_d=$1; shift
	if _out=$("$@" 2>&1); then t__result 1 "$_d" "command unexpectedly succeeded: $* :: $_out"; else t__result 0 "$_d"; fi
}

t_eq() {
	if [ "$2" = "$3" ]; then t__result 0 "$1"; else t__result 1 "$1" "expected: <$2>
actual:   <$3>"; fi
}

t_match() {
	if printf '%s' "$3" | grep -Eq -- "$2"; then t__result 0 "$1"; else t__result 1 "$1" "pattern: $2
actual:  <$3>"; fi
}

t_skip() {
	T_COUNT=$((T_COUNT + 1))
	printf 'ok %d - %s # SKIP %s\n' "$T_COUNT" "$1" "$2"
}

t_diag() { printf '# %s\n' "$*"; }

t_done() {
	for _dir in $T_TMPDIRS; do rm -rf "$_dir"; done
	printf '1..%d\n' "$T_COUNT"
	[ "$T_FAILED" -eq 0 ] || { printf '# %d of %d failed\n' "$T_FAILED" "$T_COUNT"; exit 1; }
	exit 0
}

abfm_tmpdir() {
	_dir=$(mktemp -d "${TMPDIR:-/tmp}/abfm-test.XXXXXX") || return 1
	T_TMPDIRS="$T_TMPDIRS $_dir"
	printf '%s\n' "$_dir"
}

# lstat through ucode. Prints FORMAT with these tokens replaced:
#   %u uid  %g gid  %a octal permission bits  %s size  %i inode
#   %F type (file, directory, link, fifo, socket, char, block)  %Y mtime
# Returns 1 if PATH does not exist.
abfm_stat() {
	ucode -e '
		let fs = require("fs");
		let st = fs.lstat(ARGV[1]);
		if (!st) exit(1);
		print(replace(ARGV[0], /%[ugasiFY]/g, (m) => {
			switch (m) {
			case "%u": return st.uid;
			case "%g": return st.gid;
			case "%a": return sprintf("%o", st.mode & 4095);
			case "%s": return st.size;
			case "%i": return st.inode;
			case "%F": return st.type;
			case "%Y": return st.mtime;
			}
		}), "\n");
	' -- "$1" "$2"
}

abfm_timeout() {
	_secs=$1; shift
	"$@" &
	_pid=$!
	(
		_ticks=$_secs
		while [ "$_ticks" -gt 0 ]; do
			sleep 1
			kill -0 "$_pid" 2>/dev/null || exit 0
			_ticks=$((_ticks - 1))
		done
		kill -TERM "$_pid" 2>/dev/null
		exit 124
	) &
	_wd=$!
	wait "$_pid"
	_rc=$?
	wait "$_wd"
	[ $? -eq 124 ] && return 124
	return "$_rc"
}

abfm_wait_until() {
	_deadline=$(( $(date +%s) + $1 )); shift
	until "$@" >/dev/null 2>&1; do
		[ "$(date +%s)" -lt "$_deadline" ] || return 1
		sleep 1
	done
}
