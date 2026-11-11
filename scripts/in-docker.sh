#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runs a command in a fresh Linux validation container (Dockerfile.validation).
# Use it on macOS (or anywhere without QEMU) for guest runs and SDK builds.
#
#   scripts/in-docker.sh [--platform linux/amd64] [--] COMMAND [ARGS...]
#
# - The worktree is mounted at /workspace. If .local-validation is a symlink
#   to a shared cache, the target is also mounted at its own absolute path so
#   the symlink and qcow2 backing paths resolve inside the container.
# - In a git worktree (.git is a file), the repository's common git directory
#   is mounted read-only at its own absolute path, so git (e.g. the git HEAD
#   source of scripts/build-package.sh) works inside the container.
# - Each call gets its own container (removed afterwards) and therefore its
#   own network namespace: guests in concurrent containers never share ports.
# - Platform defaults to the Docker host's native one (fastest for QEMU TCG);
#   the OpenWrt SDK needs --platform linux/amd64.
# - GUEST_*, ABFM_*, PACKAGE_*, MONITOR_*, PLAYWRIGHT_*, CI and OPENWRT_SDK are
#   passed through. /dev/kvm is passed through when present.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform=''
while (($#)); do
	case "$1" in
		--platform) platform="$2"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done
(($#)) || { echo 'usage: scripts/in-docker.sh [--platform P] [--] COMMAND [ARGS...]' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'in-docker: Docker daemon is unavailable' >&2; exit 1; }

arch="${platform:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}"
hash="$({ sha256sum 2>/dev/null || shasum -a 256; } <"$root/Dockerfile.validation" | cut -c1-12)"
image="abfm-validation:$hash-${arch//\//-}"
if ! docker image inspect "$image" >/dev/null 2>&1; then
	docker build --quiet --platform "$arch" --tag "$image" --file "$root/Dockerfile.validation" "$root" >/dev/null
fi

mounts=(--mount "type=bind,src=$root,dst=/workspace")
if [[ -L "$root/.local-validation" ]]; then
	shared="$(cd "$root/.local-validation" && pwd -P)"
	mounts+=(--mount "type=bind,src=$shared,dst=$shared")
fi
if [[ -f "$root/.git" ]]; then
	common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
	[[ -z "$common" || ! -d "$common" ]] || mounts+=(--mount "type=bind,src=$common,dst=$common,readonly")
fi
# Linux node_modules per platform, so host (e.g. macOS) modules are never reused.
mounts+=(--mount "type=volume,src=abfm-node-modules-${arch//\//-},dst=/workspace/node_modules")

envs=()
while IFS='=' read -r name _; do
	case "$name" in
		GUEST_* | ABFM_* | PACKAGE_* | MONITOR_* | PLAYWRIGHT_* | CI | OPENWRT_SDK) envs+=(--env "$name") ;;
	esac
done < <(env)
devices=()
[[ -e /dev/kvm ]] && devices=(--device /dev/kvm)
tty=()
[[ -t 0 && -t 1 ]] && tty=(--interactive --tty)

exec docker run --rm "${tty[@]}" --platform "$arch" --name "abfm-$(date +%s)-$$-$RANDOM" \
	"${mounts[@]}" "${envs[@]}" "${devices[@]}" --workdir /workspace \
	--env PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/workspace/.local-validation/playwright-${arch//\//-}}" \
	"$image" "$@"
