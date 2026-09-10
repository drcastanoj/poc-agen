#!/usr/bin/env bash
# Packages lambda/api and lambda/dispatcher into deployable zips. Both are
# plain Node + the AWS SDK v3 clients they import — no exotic binaries, unlike
# lambda/publish, which needs git/gh and ships as a container image instead
# (see build-images.sh).
#
# Usage: ./build-lambda-zips.sh
# Produces: /tmp/poc-agent-lambda-api.zip, /tmp/poc-agent-lambda-dispatcher.zip

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { printf '\n=== %s ===\n' "$*"; }

for name in api dispatcher; do
  log "packaging lambda/$name"
  src="$REPO_ROOT/lambda/$name"
  build="/tmp/poc-agent-lambda-$name-build"
  zip_path="/tmp/poc-agent-lambda-$name.zip"
  rm -rf "$build" "$zip_path"
  mkdir -p "$build"
  cp "$src/index.js" "$src/package.json" "$build/"
  ( cd "$build" && npm install --omit=dev --no-audit --no-fund --silent )
  ( cd "$build" && zip -qr "$zip_path" . )
  rm -rf "$build"
  echo "$zip_path"
done
