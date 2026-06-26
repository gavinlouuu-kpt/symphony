#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTANCE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE=${SYMPHONY_ENV_FILE:-"$INSTANCE_ROOT/symphony.env"}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Copy symphony.env.example to symphony.env and fill required values." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

SYMPHONY_INSTANCE_ID=${SYMPHONY_INSTANCE_ID:-$(basename "$INSTANCE_ROOT")}
SYMPHONY_CODE_DIR=${SYMPHONY_CODE_DIR:-/home/gavin/Developer/symphony}
SYMPHONY_INSTANCE_ROOT=${SYMPHONY_INSTANCE_ROOT:-"$INSTANCE_ROOT"}
SYMPHONY_RUNTIME_ROOT=${SYMPHONY_RUNTIME_ROOT:-"$SYMPHONY_INSTANCE_ROOT/runtime"}
SYMPHONY_LOGS_ROOT=${SYMPHONY_LOGS_ROOT:-"$SYMPHONY_INSTANCE_ROOT/log"}
SYMPHONY_EVIDENCE_ROOT=${SYMPHONY_EVIDENCE_ROOT:-"$SYMPHONY_INSTANCE_ROOT/evidence"}
SYMPHONY_WORKSPACE_ROOT=${SYMPHONY_WORKSPACE_ROOT:-"$SYMPHONY_INSTANCE_ROOT/workspaces"}
SYMPHONY_DASHBOARD_PORT=${SYMPHONY_DASHBOARD_PORT:-4401}
SYMPHONY_DASHBOARD_HOST=${SYMPHONY_DASHBOARD_HOST:-127.0.0.1}
SYMPHONY_POLL_INTERVAL_MS=${SYMPHONY_POLL_INTERVAL_MS:-30000}
SYMPHONY_MAX_CONCURRENT_AGENTS=${SYMPHONY_MAX_CONCURRENT_AGENTS:-2}
SYMPHONY_MAX_TURNS=${SYMPHONY_MAX_TURNS:-20}
SYMPHONY_SOURCE_REPO_BRANCH=${SYMPHONY_SOURCE_REPO_BRANCH:-main}
SYMPHONY_AFTER_CREATE_EXTRA=${SYMPHONY_AFTER_CREATE_EXTRA:-}
SYMPHONY_CUA_HOST=${SYMPHONY_CUA_HOST:-127.0.0.1}
SYMPHONY_CUA_IMAGE=${SYMPHONY_CUA_IMAGE:-symphony-cua-worker:latest}
SYMPHONY_CUA_IMAGE_BUILD=${SYMPHONY_CUA_IMAGE_BUILD:-auto}
SYMPHONY_CUA_NAME_PREFIX=${SYMPHONY_CUA_NAME_PREFIX:-"symphony-$SYMPHONY_INSTANCE_ID"}
SYMPHONY_CUA_SSH_KEYGEN=${SYMPHONY_CUA_SSH_KEYGEN:-auto}
SYMPHONY_CUA_SSH_IDENTITY_FILE=${SYMPHONY_CUA_SSH_IDENTITY_FILE:-"$SYMPHONY_INSTANCE_ROOT/ssh/id_ed25519"}
SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH=${SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH:-"$SYMPHONY_CUA_SSH_IDENTITY_FILE.pub"}
SYMPHONY_CUA_DELETE_ON_TERMINAL=${SYMPHONY_CUA_DELETE_ON_TERMINAL:-false}
SYMPHONY_CUA_LAUNCH_TIMEOUT_MS=${SYMPHONY_CUA_LAUNCH_TIMEOUT_MS:-120000}
SYMPHONY_CUA_GPU=${SYMPHONY_CUA_GPU:-none}
SYMPHONY_TAILSERVE_ENABLED=${SYMPHONY_TAILSERVE_ENABLED:-false}
SYMPHONY_CODEX_COMMAND=${SYMPHONY_CODEX_COMMAND:-'codex --config shell_environment_policy.inherit=all --config model=\"gpt-5.5\" --config model_reasoning_effort=xhigh app-server'}

WORKFLOW_TEMPLATE=${SYMPHONY_WORKFLOW_TEMPLATE:-"$SYMPHONY_INSTANCE_ROOT/WORKFLOW.md.template"}
RUNTIME_WORKFLOW=${SYMPHONY_RUNTIME_WORKFLOW:-"$SYMPHONY_RUNTIME_ROOT/WORKFLOW.runtime.md"}

required_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required in $ENV_FILE" >&2
    exit 1
  fi
}

replace_token() {
  local key=$1
  local value=$2
  local escaped
  escaped=${value//\\/\\\\}
  escaped=${escaped//&/\\&}
  escaped=${escaped//|/\\|}
  sed -i "s|@$key@|$escaped|g" "$RUNTIME_WORKFLOW"
}

render_workflow() {
  if [[ ! -f "$WORKFLOW_TEMPLATE" ]]; then
    echo "Workflow template not found: $WORKFLOW_TEMPLATE" >&2
    exit 1
  fi

  mkdir -p "$SYMPHONY_RUNTIME_ROOT"
  cp "$WORKFLOW_TEMPLATE" "$RUNTIME_WORKFLOW"

  replace_token SYMPHONY_LINEAR_PROJECT_SLUG "$SYMPHONY_LINEAR_PROJECT_SLUG"
  replace_token SYMPHONY_POLL_INTERVAL_MS "$SYMPHONY_POLL_INTERVAL_MS"
  replace_token SYMPHONY_WORKSPACE_ROOT "$SYMPHONY_WORKSPACE_ROOT"
  replace_token SYMPHONY_CUA_HOST "$SYMPHONY_CUA_HOST"
  replace_token SYMPHONY_CUA_IMAGE "$SYMPHONY_CUA_IMAGE"
  replace_token SYMPHONY_CUA_NAME_PREFIX "$SYMPHONY_CUA_NAME_PREFIX"
  replace_token SYMPHONY_CUA_SSH_IDENTITY_FILE "$SYMPHONY_CUA_SSH_IDENTITY_FILE"
  replace_token SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH"
  replace_token SYMPHONY_CUA_DELETE_ON_TERMINAL "$SYMPHONY_CUA_DELETE_ON_TERMINAL"
  replace_token SYMPHONY_CUA_LAUNCH_TIMEOUT_MS "$SYMPHONY_CUA_LAUNCH_TIMEOUT_MS"
  replace_token SYMPHONY_CUA_GPU "$SYMPHONY_CUA_GPU"
  replace_token SYMPHONY_SOURCE_REPO_BRANCH "$SYMPHONY_SOURCE_REPO_BRANCH"
  replace_token SYMPHONY_SOURCE_REPO_URL "$SYMPHONY_SOURCE_REPO_URL"
  replace_token SYMPHONY_AFTER_CREATE_EXTRA "$SYMPHONY_AFTER_CREATE_EXTRA"
  replace_token SYMPHONY_MAX_CONCURRENT_AGENTS "$SYMPHONY_MAX_CONCURRENT_AGENTS"
  replace_token SYMPHONY_MAX_TURNS "$SYMPHONY_MAX_TURNS"
  replace_token SYMPHONY_CODEX_COMMAND "$SYMPHONY_CODEX_COMMAND"
  replace_token SYMPHONY_DASHBOARD_HOST "$SYMPHONY_DASHBOARD_HOST"
  replace_token SYMPHONY_DASHBOARD_PORT "$SYMPHONY_DASHBOARD_PORT"
}

ensure_cua_ssh_key_if_needed() {
  case "$SYMPHONY_CUA_SSH_KEYGEN" in
    never)
      return 0
      ;;
    auto)
      if [[ -s "$SYMPHONY_CUA_SSH_IDENTITY_FILE" && -s "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH" ]]; then
        return 0
      fi

      if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "ssh-keygen is required to create the CUA SSH keypair" >&2
        exit 1
      fi

      mkdir -p "$(dirname "$SYMPHONY_CUA_SSH_IDENTITY_FILE")"
      chmod 700 "$(dirname "$SYMPHONY_CUA_SSH_IDENTITY_FILE")"
      ssh-keygen -t ed25519 -N "" -f "$SYMPHONY_CUA_SSH_IDENTITY_FILE" -C "symphony-$SYMPHONY_INSTANCE_ID-cua" >/dev/null
      chmod 600 "$SYMPHONY_CUA_SSH_IDENTITY_FILE"
      chmod 644 "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH"
      ;;
    *)
      echo "Invalid SYMPHONY_CUA_SSH_KEYGEN=$SYMPHONY_CUA_SSH_KEYGEN. Use auto or never." >&2
      exit 1
      ;;
  esac
}

build_cua_image_if_needed() {
  case "$SYMPHONY_CUA_IMAGE_BUILD" in
    never)
      return 0
      ;;
    always)
      "$SCRIPT_DIR/build-cua-image.sh"
      ;;
    auto)
      if ! docker image inspect "$SYMPHONY_CUA_IMAGE" >/dev/null 2>&1; then
        "$SCRIPT_DIR/build-cua-image.sh"
      fi
      ;;
    *)
      echo "Invalid SYMPHONY_CUA_IMAGE_BUILD=$SYMPHONY_CUA_IMAGE_BUILD. Use auto, always, or never." >&2
      exit 1
      ;;
  esac
}

required_env LINEAR_API_KEY
required_env SYMPHONY_LINEAR_PROJECT_SLUG
required_env SYMPHONY_SOURCE_REPO_URL

if [[ ! -d "$SYMPHONY_CODE_DIR/elixir" ]]; then
  echo "Symphony checkout not found at $SYMPHONY_CODE_DIR" >&2
  exit 1
fi

ensure_cua_ssh_key_if_needed

mkdir -p "$SYMPHONY_INSTANCE_ROOT" "$SYMPHONY_RUNTIME_ROOT" "$SYMPHONY_LOGS_ROOT" "$SYMPHONY_EVIDENCE_ROOT"
render_workflow

if [[ "${SYMPHONY_RENDER_ONLY:-0}" == "1" ]]; then
  echo "Rendered workflow: $RUNTIME_WORKFLOW"
  exit 0
fi

build_cua_image_if_needed

if [[ "$SYMPHONY_TAILSERVE_ENABLED" == "true" ]]; then
  "$SCRIPT_DIR/tailserve.sh"
fi

export LINEAR_API_KEY
export SYMPHONY_EVIDENCE_ROOT
export SYMPHONY_INSTANCE_ROOT

cd "$SYMPHONY_CODE_DIR/elixir"

if command -v mise >/dev/null 2>&1; then
  mise trust >/dev/null 2>&1 || true
  mise install
  mise exec -- mix deps.get
  mise exec -- mix build
  exec mise exec -- ./bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --logs-root "$SYMPHONY_LOGS_ROOT" \
    --port "$SYMPHONY_DASHBOARD_PORT" \
    "$RUNTIME_WORKFLOW"
fi

if command -v mix >/dev/null 2>&1; then
  mix deps.get
  mix build
  exec ./bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --logs-root "$SYMPHONY_LOGS_ROOT" \
    --port "$SYMPHONY_DASHBOARD_PORT" \
    "$RUNTIME_WORKFLOW"
fi

echo "Neither mise nor mix is available. Install mise or Elixir/Mix, then rerun." >&2
exit 1
