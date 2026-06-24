#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTANCE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE=${SYMPHONY_ENV_FILE:-"$INSTANCE_ROOT/symphony.env"}
FAILED=0

check_ok() {
  printf '[ok] %s\n' "$1"
}

check_fail() {
  printf '[fail] %s\n' "$1" >&2
  FAILED=1
}

check_warn() {
  printf '[warn] %s\n' "$1" >&2
}

if [[ ! -f "$ENV_FILE" ]]; then
  check_fail "missing env file: $ENV_FILE"
else
  check_ok "env file exists: $ENV_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

SYMPHONY_CODE_DIR=${SYMPHONY_CODE_DIR:-/home/gavin/Developer/symphony}
SYMPHONY_INSTANCE_ROOT=${SYMPHONY_INSTANCE_ROOT:-"$INSTANCE_ROOT"}
SYMPHONY_DASHBOARD_PORT=${SYMPHONY_DASHBOARD_PORT:-4401}
SYMPHONY_CUA_IMAGE=${SYMPHONY_CUA_IMAGE:-symphony-cua-worker:latest}
SYMPHONY_CUA_IMAGE_BUILD=${SYMPHONY_CUA_IMAGE_BUILD:-auto}

[[ -n "${LINEAR_API_KEY:-}" ]] && check_ok "LINEAR_API_KEY is set" || check_fail "LINEAR_API_KEY is missing"
[[ -n "${SYMPHONY_LINEAR_PROJECT_SLUG:-}" ]] && check_ok "SYMPHONY_LINEAR_PROJECT_SLUG is set" || check_fail "SYMPHONY_LINEAR_PROJECT_SLUG is missing"
[[ -n "${SYMPHONY_SOURCE_REPO_URL:-}" ]] && check_ok "SYMPHONY_SOURCE_REPO_URL is set" || check_fail "SYMPHONY_SOURCE_REPO_URL is missing"

[[ -d "$SYMPHONY_CODE_DIR/elixir" ]] && check_ok "Symphony checkout found" || check_fail "Symphony checkout missing at $SYMPHONY_CODE_DIR"
[[ -f "$SYMPHONY_INSTANCE_ROOT/WORKFLOW.md.template" ]] && check_ok "workflow template found" || check_fail "workflow template missing"

if command -v docker >/dev/null 2>&1; then
  check_ok "docker CLI found"
  if docker info >/dev/null 2>&1; then
    check_ok "docker daemon reachable"
  else
    check_fail "docker daemon is not reachable"
  fi

  if docker image inspect "$SYMPHONY_CUA_IMAGE" >/dev/null 2>&1; then
    check_ok "CUA image exists: $SYMPHONY_CUA_IMAGE"
  elif [[ "$SYMPHONY_CUA_IMAGE_BUILD" == "auto" || "$SYMPHONY_CUA_IMAGE_BUILD" == "always" ]]; then
    check_warn "CUA image missing but SYMPHONY_CUA_IMAGE_BUILD=$SYMPHONY_CUA_IMAGE_BUILD can build it"
  else
    check_fail "CUA image missing: $SYMPHONY_CUA_IMAGE"
  fi
else
  check_fail "docker CLI not found"
fi

if command -v mise >/dev/null 2>&1; then
  check_ok "mise found"
elif command -v mix >/dev/null 2>&1; then
  check_ok "mix found"
else
  check_fail "neither mise nor mix found"
fi

if command -v codex >/dev/null 2>&1; then
  check_ok "codex found: $(codex --version 2>/dev/null || true)"
else
  check_fail "codex CLI not found on host"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$SYMPHONY_DASHBOARD_PORT )" | tail -n +2 | grep -q .; then
    check_warn "dashboard port appears in use: $SYMPHONY_DASHBOARD_PORT"
  else
    check_ok "dashboard port appears available: $SYMPHONY_DASHBOARD_PORT"
  fi
else
  check_warn "ss not found; skipped dashboard port check"
fi

if [[ "${SYMPHONY_DOCTOR_ONLINE:-0}" == "1" && -n "${LINEAR_API_KEY:-}" ]]; then
  if curl -fsS \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    https://api.linear.app/graphql \
    --data-binary '{"query":"query Viewer { viewer { id } }"}' \
    | grep -q '"viewer"'; then
    check_ok "Linear API reachable"
  else
    check_fail "Linear API check failed"
  fi
else
  check_warn "skipped Linear online check; set SYMPHONY_DOCTOR_ONLINE=1 to enable"
fi

if [[ "$FAILED" == "0" ]]; then
  check_ok "project template checks passed"
else
  exit 1
fi

