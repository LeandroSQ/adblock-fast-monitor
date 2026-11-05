#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'local Docker validation: %s\n' "$*" >&2; exit 1; }

docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 ||
	fail 'Docker daemon endpoint is unavailable; start a local daemon and retry.'

image='adblock-fast-monitor-validation:local'
timeout 15m docker build --platform linux/amd64 --tag "$image" --file Dockerfile.validation .
timeout 45m docker run --rm \
	--platform linux/amd64 \
	--network bridge \
	--env LIBGUESTFS_BACKEND=direct \
	--mount "type=bind,src=$PWD,dst=/workspace" \
	--workdir /workspace \
	"$image"
