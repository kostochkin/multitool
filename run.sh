#!/usr/bin/env bash
# Run the sbcl-multitool container manually.
#
# Modes:
#   ./run.sh            start a detached dev-session (attach via SLIME/Sly)
#   ./run.sh --pipe     foreground: type miniswank JSON-lines by hand
#   ./run.sh --stop     stop and remove the dev container
#
# Environment:
#   MULTITOOL_IMAGE       image tag      (default sbcl-multitool:latest)
#   MULTITOOL_WORKDIR     host dir mounted at /work (default: repo root)
#   MULTITOOL_SWANK_PORT  host port for swank (default 4005)
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${MULTITOOL_IMAGE:-sbcl-multitool:latest}"
WORKDIR="${MULTITOOL_WORKDIR:-$(pwd)}"
SWANK_PORT="${MULTITOOL_SWANK_PORT:-4005}"
NAME="sbcl-multitool-dev"

die() { echo "error: $*" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  die "image $IMAGE not found — run ./build.sh first"
fi

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

case "${1:-}" in
  --stop)
    if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
      cleanup
      echo "stopped $NAME"
    else
      echo "$NAME is not running"
    fi
    exit 0
    ;;
esac

# Idempotent: replace an old dev container with the same name.
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "removing stale container $NAME"
  cleanup
fi

DOCKER_ARGS=(
  --name "$NAME"
  --network bridge
  --memory 512m
  --cpus=1
  -v "$WORKDIR:/work"
  -w /work
  -p "$SWANK_PORT:4005"
)

case "${1:-}" in
  --pipe)
    echo "miniswank protocol over stdio; Ctrl-D to exit"
    echo 'try: {"id":"1","method":"eval","params":{"form":"(+ 1 2)"}}'
    exec docker run -i "${DOCKER_ARGS[@]}" "$IMAGE"
    ;;
  "")
    # -d alone closes stdin -> miniswank loop hits EOF -> SBCL quits,
    # so keep stdin open with -d -i (container stays up).
    docker run -d -i "${DOCKER_ARGS[@]}" "$IMAGE" >/dev/null
    echo "container $NAME is up"
    echo "  attach: M-x slime-connect RET localhost RET $SWANK_PORT"
    echo "  stop:   ./run.sh --stop"
    ;;
  *)
    die "unknown mode: $1 (use: (none) | --pipe | --stop)"
    ;;
esac
