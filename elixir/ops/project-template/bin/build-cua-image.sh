#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTANCE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE=${SYMPHONY_ENV_FILE:-"$INSTANCE_ROOT/symphony.env"}

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

SYMPHONY_CODE_DIR=${SYMPHONY_CODE_DIR:-/home/gavin/Developer/symphony}
SYMPHONY_CUA_IMAGE=${SYMPHONY_CUA_IMAGE:-symphony-cua-worker:latest}

if [[ ! -d "$SYMPHONY_CODE_DIR/elixir/support/cua_worker" ]]; then
  echo "CUA worker Dockerfile not found under $SYMPHONY_CODE_DIR/elixir/support/cua_worker" >&2
  exit 1
fi

docker build -t "$SYMPHONY_CUA_IMAGE" "$SYMPHONY_CODE_DIR/elixir/support/cua_worker"

