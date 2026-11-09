#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'local Docker validation: %s\n' "$*" >&2; exit 1; }

docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 ||
	fail 'Docker daemon endpoint is unavailable; start a local daemon and retry.'
mkdir -p .local-validation/playwright

image='adblock-fast-monitor-validation:local'
container="adblock-fast-monitor-validation-local-$(date +%Y%m%dT%H%M%S)"
docker build --platform linux/amd64 --tag "$image" --file Dockerfile.validation .
docker run --detach \
	--name "$container" \
	--platform linux/amd64 \
	--network bridge \
	--cpus 8 \
	--memory 12g \
	--env LIBGUESTFS_BACKEND=direct \
	--env PLAYWRIGHT_BROWSERS_PATH=/workspace/.local-validation/playwright \
	--env REBUILD_PACKAGE="${REBUILD_PACKAGE:-0}" \
	--env READER_ONLY_DIAGNOSTIC="${READER_ONLY_DIAGNOSTIC:-0}" \
	--mount "type=bind,src=$PWD,dst=/workspace" \
	--workdir /workspace \
	"$image"
printf 'validation container: %s\n' "$container"
