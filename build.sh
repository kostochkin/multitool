#!/usr/bin/env bash
# Build the sbcl-multitool Docker image.
# Usage: ./build.sh [--no-cache]
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${MULTITOOL_IMAGE:-sbcl-multitool:latest}"
LOG="${TMPDIR:-/tmp}/sbcl-multitool-build.log"

EXTRA=()
if [[ "${1:-}" == "--no-cache" ]]; then
  EXTRA+=(--no-cache)
fi

docker build "${EXTRA[@]}" -t "$IMAGE" .

