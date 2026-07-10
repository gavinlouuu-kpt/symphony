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
SYMPHONY_MAX_CONCURRENT_AGENTS=${SYMPHONY_MAX_CONCURRENT_AGENTS:-4}
SYMPHONY_MAX_TURNS=${SYMPHONY_MAX_TURNS:-20}
SYMPHONY_UNROUTE_GRACE_MS=${SYMPHONY_UNROUTE_GRACE_MS:-300000}
SYMPHONY_CODEX_STALL_TIMEOUT_MS=${SYMPHONY_CODEX_STALL_TIMEOUT_MS:-1800000}
SYMPHONY_OPENCLAW_ENABLED=${SYMPHONY_OPENCLAW_ENABLED:-false}
SYMPHONY_OPENCLAW_COMMAND=${SYMPHONY_OPENCLAW_COMMAND:-openclaw}
SYMPHONY_OPENCLAW_CHANNEL=${SYMPHONY_OPENCLAW_CHANNEL:-discord}
SYMPHONY_OPENCLAW_ACCOUNT=${SYMPHONY_OPENCLAW_ACCOUNT:-}
SYMPHONY_OPENCLAW_TARGET=${SYMPHONY_OPENCLAW_TARGET:-}
SYMPHONY_OPENCLAW_TIMEOUT_MS=${SYMPHONY_OPENCLAW_TIMEOUT_MS:-10000}
SYMPHONY_OPENCLAW_INTAKE_ENABLED=${SYMPHONY_OPENCLAW_INTAKE_ENABLED:-false}
SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV=${SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV:-SYMPHONY_OPENCLAW_INTAKE_TOKEN}
SYMPHONY_OPENCLAW_INTAKE_LABELS=${SYMPHONY_OPENCLAW_INTAKE_LABELS:-[]}
SYMPHONY_OPENCLAW_INTAKE_URL=${SYMPHONY_OPENCLAW_INTAKE_URL:-"http://$SYMPHONY_DASHBOARD_HOST:$SYMPHONY_DASHBOARD_PORT/api/v1/openclaw/issues"}
SYMPHONY_OPENCLAW_EVENTS=${SYMPHONY_OPENCLAW_EVENTS:-'["dispatch_started", "role_agent_completed", "agent_completed", "issue_blocked", "retry_scheduled", "issue_unrouted", "routing_label_restored"]'}
SYMPHONY_TRACKER_KIND=${SYMPHONY_TRACKER_KIND:-linear}
case "$SYMPHONY_TRACKER_KIND" in
  github)
    SYMPHONY_TRACKER_ENDPOINT=${SYMPHONY_TRACKER_ENDPOINT:-https://api.github.com}
    SYMPHONY_TRACKER_API_KEY_ENV=${SYMPHONY_TRACKER_API_KEY_ENV:-GITHUB_TOKEN}
    SYMPHONY_TRACKER_PROJECT=${SYMPHONY_TRACKER_PROJECT:-${SYMPHONY_GITHUB_REPOSITORY:-}}
    # symphony = bookkeeping label; openclaw-intake = active routing label that
    # Symphony's premature-handoff safeguard restores when evidence is unmet.
    SYMPHONY_TRACKER_REQUIRED_LABELS=${SYMPHONY_TRACKER_REQUIRED_LABELS:-'["symphony", "openclaw-intake"]'}
    SYMPHONY_TRACKER_ACTIVE_STATES=${SYMPHONY_TRACKER_ACTIVE_STATES:-'["open"]'}
    SYMPHONY_TRACKER_TERMINAL_STATES=${SYMPHONY_TRACKER_TERMINAL_STATES:-'["closed"]'}
    SYMPHONY_OPENCLAW_INTAKE_LABELS=${SYMPHONY_OPENCLAW_INTAKE_LABELS:-'["openclaw-intake"]'}
    # Pass tracker tokens into sandboxes so private clones and in-sandbox gh work.
    SYMPHONY_CUA_DOCKER_ARGS=${SYMPHONY_CUA_DOCKER_ARGS:-'["--env", "GITHUB_TOKEN", "--env", "GH_TOKEN"]'}
    ;;
  linear)
    SYMPHONY_TRACKER_ENDPOINT=${SYMPHONY_TRACKER_ENDPOINT:-https://api.linear.app/graphql}
    SYMPHONY_TRACKER_API_KEY_ENV=${SYMPHONY_TRACKER_API_KEY_ENV:-LINEAR_API_KEY}
    SYMPHONY_TRACKER_PROJECT=${SYMPHONY_TRACKER_PROJECT:-${SYMPHONY_LINEAR_PROJECT_SLUG:-}}
    SYMPHONY_TRACKER_REQUIRED_LABELS=${SYMPHONY_TRACKER_REQUIRED_LABELS:-[]}
    SYMPHONY_TRACKER_ACTIVE_STATES=${SYMPHONY_TRACKER_ACTIVE_STATES:-'["Todo", "In Progress", "Rework", "Merging", "Human Review"]'}
    SYMPHONY_TRACKER_TERMINAL_STATES=${SYMPHONY_TRACKER_TERMINAL_STATES:-'["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]'}
    ;;
  *)
    echo "Invalid SYMPHONY_TRACKER_KIND=$SYMPHONY_TRACKER_KIND. Use linear or github." >&2
    exit 1
    ;;
esac
SYMPHONY_SOURCE_REPO_BRANCH=${SYMPHONY_SOURCE_REPO_BRANCH:-main}
SYMPHONY_AFTER_CREATE_EXTRA=${SYMPHONY_AFTER_CREATE_EXTRA:-}
SYMPHONY_SANDBOX_CONTRACT_ENFORCED=${SYMPHONY_SANDBOX_CONTRACT_ENFORCED:-true}
SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=${SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED:-false}
SYMPHONY_SANDBOX_REQUIRED_COMMANDS=${SYMPHONY_SANDBOX_REQUIRED_COMMANDS:-[]}
SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES=${SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES:-[]}
SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES=${SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES:-[]}
SYMPHONY_SANDBOX_BOOTSTRAP_CHECK=${SYMPHONY_SANDBOX_BOOTSTRAP_CHECK:-}
SYMPHONY_SANDBOX_REQUIREMENTS_NOTES=${SYMPHONY_SANDBOX_REQUIREMENTS_NOTES:-}
SYMPHONY_EVIDENCE_CONTRACT_ENFORCED=${SYMPHONY_EVIDENCE_CONTRACT_ENFORCED:-true}
SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=${SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED:-false}
SYMPHONY_EVIDENCE_REQUIRED_CHECKS=${SYMPHONY_EVIDENCE_REQUIRED_CHECKS:-[]}
SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS=${SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS:-[]}
SYMPHONY_EVIDENCE_REQUIRED_COMMANDS=${SYMPHONY_EVIDENCE_REQUIRED_COMMANDS:-[]}
SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES=${SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES:-}
SYMPHONY_CUA_HOST=${SYMPHONY_CUA_HOST:-127.0.0.1}
SYMPHONY_CUA_IMAGE=${SYMPHONY_CUA_IMAGE:-symphony-cua-worker:latest}
SYMPHONY_CUA_IMAGE_BUILD=${SYMPHONY_CUA_IMAGE_BUILD:-auto}
SYMPHONY_CUA_NAME_PREFIX=${SYMPHONY_CUA_NAME_PREFIX:-"symphony-$SYMPHONY_INSTANCE_ID"}
SYMPHONY_CUA_SSH_KEYGEN=${SYMPHONY_CUA_SSH_KEYGEN:-auto}
SYMPHONY_CUA_SSH_IDENTITY_FILE=${SYMPHONY_CUA_SSH_IDENTITY_FILE:-"$SYMPHONY_INSTANCE_ROOT/ssh/id_ed25519"}
SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH=${SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH:-"$SYMPHONY_CUA_SSH_IDENTITY_FILE.pub"}
SYMPHONY_CUA_DELETE_ON_TERMINAL=${SYMPHONY_CUA_DELETE_ON_TERMINAL:-false}
SYMPHONY_CUA_LAUNCH_TIMEOUT_MS=${SYMPHONY_CUA_LAUNCH_TIMEOUT_MS:-120000}
SYMPHONY_CUA_DOCKER_ARGS=${SYMPHONY_CUA_DOCKER_ARGS:-[]}
# Default codex command strips tracker/bridge tokens from agent shells and
# points gh at an empty config dir so host-side GitHub writes cannot bypass the
# sandbox-tool handoff guards (the sandbox keeps its own injected token).
SYMPHONY_CODEX_COMMAND=${SYMPHONY_CODEX_COMMAND:-'codex --config shell_environment_policy.inherit=all --config shell_environment_policy.exclude=[\"GH_TOKEN\",\"GITHUB_TOKEN\",\"LINEAR_API_KEY\",\"SYMPHONY_OPENCLAW_*\"] --config shell_environment_policy.set.GH_CONFIG_DIR=\"/tmp/symphony-no-host-gh\" --config model=\"gpt-5.5\" --config model_reasoning_effort=xhigh app-server'}

WORKFLOW_TEMPLATE=${SYMPHONY_WORKFLOW_TEMPLATE:-"$SYMPHONY_INSTANCE_ROOT/WORKFLOW.md.template"}
RUNTIME_WORKFLOW=${SYMPHONY_RUNTIME_WORKFLOW:-"$SYMPHONY_RUNTIME_ROOT/WORKFLOW.runtime.md"}

required_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required in $ENV_FILE" >&2
    exit 1
  fi
}

has_config_value() {
  local value=${1:-}
  local compact
  compact=$(printf '%s' "$value" | tr -d '[:space:]')
  [[ -n "$compact" && "$compact" != "[]" && "$compact" != "''" && "$compact" != '""' ]]
}

validate_sandbox_requirements() {
  case "$SYMPHONY_SANDBOX_CONTRACT_ENFORCED" in
    true)
      ;;
    false)
      return 0
      ;;
    *)
      echo "Invalid SYMPHONY_SANDBOX_CONTRACT_ENFORCED=$SYMPHONY_SANDBOX_CONTRACT_ENFORCED. Use true or false." >&2
      exit 1
      ;;
  esac

  case "$SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED" in
    true)
      ;;
    false)
      echo "SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED must be true before starting a project instance." >&2
      echo "Review repo docs/CI/package manifests, declare sandbox requirements, and set SYMPHONY_SANDBOX_BOOTSTRAP_CHECK." >&2
      exit 1
      ;;
    *)
      echo "Invalid SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=$SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED. Use true or false." >&2
      exit 1
      ;;
  esac

  if ! has_config_value "$SYMPHONY_SANDBOX_BOOTSTRAP_CHECK"; then
    echo "SYMPHONY_SANDBOX_BOOTSTRAP_CHECK is required when sandbox contract enforcement is enabled." >&2
    exit 1
  fi

  if ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_COMMANDS" \
    && ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES" \
    && ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES" \
    && ! has_config_value "$SYMPHONY_SANDBOX_REQUIREMENTS_NOTES"; then
    echo "Declare at least one sandbox requirement or note before starting a project instance." >&2
    exit 1
  fi
}

validate_evidence_requirements() {
  case "$SYMPHONY_EVIDENCE_CONTRACT_ENFORCED" in
    true)
      ;;
    false)
      return 0
      ;;
    *)
      echo "Invalid SYMPHONY_EVIDENCE_CONTRACT_ENFORCED=$SYMPHONY_EVIDENCE_CONTRACT_ENFORCED. Use true or false." >&2
      exit 1
      ;;
  esac

  case "$SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED" in
    true)
      ;;
    false)
      echo "SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED must be true before starting a project instance." >&2
      echo "Declare the runtime/demo evidence required before PR handoff, including artifacts and real commands." >&2
      exit 1
      ;;
    *)
      echo "Invalid SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=$SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED. Use true or false." >&2
      exit 1
      ;;
  esac

  if ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_CHECKS" \
    && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS" \
    && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_COMMANDS" \
    && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES"; then
    echo "Declare at least one evidence requirement or note before starting a project instance." >&2
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

  replace_token SYMPHONY_TRACKER_KIND "$SYMPHONY_TRACKER_KIND"
  replace_token SYMPHONY_TRACKER_ENDPOINT "$SYMPHONY_TRACKER_ENDPOINT"
  replace_token SYMPHONY_TRACKER_API_KEY_ENV "$SYMPHONY_TRACKER_API_KEY_ENV"
  replace_token SYMPHONY_TRACKER_PROJECT "$SYMPHONY_TRACKER_PROJECT"
  replace_token SYMPHONY_TRACKER_REQUIRED_LABELS "$SYMPHONY_TRACKER_REQUIRED_LABELS"
  replace_token SYMPHONY_TRACKER_ACTIVE_STATES "$SYMPHONY_TRACKER_ACTIVE_STATES"
  replace_token SYMPHONY_TRACKER_TERMINAL_STATES "$SYMPHONY_TRACKER_TERMINAL_STATES"
  replace_token SYMPHONY_POLL_INTERVAL_MS "$SYMPHONY_POLL_INTERVAL_MS"
  replace_token SYMPHONY_WORKSPACE_ROOT "$SYMPHONY_WORKSPACE_ROOT"
  replace_token SYMPHONY_CUA_HOST "$SYMPHONY_CUA_HOST"
  replace_token SYMPHONY_CUA_IMAGE "$SYMPHONY_CUA_IMAGE"
  replace_token SYMPHONY_CUA_NAME_PREFIX "$SYMPHONY_CUA_NAME_PREFIX"
  replace_token SYMPHONY_CUA_SSH_IDENTITY_FILE "$SYMPHONY_CUA_SSH_IDENTITY_FILE"
  replace_token SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH"
  replace_token SYMPHONY_CUA_DELETE_ON_TERMINAL "$SYMPHONY_CUA_DELETE_ON_TERMINAL"
  replace_token SYMPHONY_CUA_LAUNCH_TIMEOUT_MS "$SYMPHONY_CUA_LAUNCH_TIMEOUT_MS"
  replace_token SYMPHONY_CUA_DOCKER_ARGS "$SYMPHONY_CUA_DOCKER_ARGS"
  replace_token SYMPHONY_SOURCE_REPO_BRANCH "$SYMPHONY_SOURCE_REPO_BRANCH"
  replace_token SYMPHONY_SOURCE_REPO_URL "$SYMPHONY_SOURCE_REPO_URL"
  replace_token SYMPHONY_AFTER_CREATE_EXTRA "$SYMPHONY_AFTER_CREATE_EXTRA"
  replace_token SYMPHONY_SANDBOX_CONTRACT_ENFORCED "$SYMPHONY_SANDBOX_CONTRACT_ENFORCED"
  replace_token SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED "$SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED"
  replace_token SYMPHONY_SANDBOX_REQUIRED_COMMANDS "$SYMPHONY_SANDBOX_REQUIRED_COMMANDS"
  replace_token SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES "$SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES"
  replace_token SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES "$SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES"
  replace_token SYMPHONY_SANDBOX_BOOTSTRAP_CHECK "$SYMPHONY_SANDBOX_BOOTSTRAP_CHECK"
  replace_token SYMPHONY_SANDBOX_REQUIREMENTS_NOTES "$SYMPHONY_SANDBOX_REQUIREMENTS_NOTES"
  replace_token SYMPHONY_EVIDENCE_CONTRACT_ENFORCED "$SYMPHONY_EVIDENCE_CONTRACT_ENFORCED"
  replace_token SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED "$SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED"
  replace_token SYMPHONY_EVIDENCE_REQUIRED_CHECKS "$SYMPHONY_EVIDENCE_REQUIRED_CHECKS"
  replace_token SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS "$SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS"
  replace_token SYMPHONY_EVIDENCE_REQUIRED_COMMANDS "$SYMPHONY_EVIDENCE_REQUIRED_COMMANDS"
  replace_token SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES "$SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES"
  replace_token SYMPHONY_MAX_CONCURRENT_AGENTS "$SYMPHONY_MAX_CONCURRENT_AGENTS"
  replace_token SYMPHONY_MAX_TURNS "$SYMPHONY_MAX_TURNS"
  replace_token SYMPHONY_UNROUTE_GRACE_MS "$SYMPHONY_UNROUTE_GRACE_MS"
  replace_token SYMPHONY_CODEX_STALL_TIMEOUT_MS "$SYMPHONY_CODEX_STALL_TIMEOUT_MS"
  replace_token SYMPHONY_OPENCLAW_ENABLED "$SYMPHONY_OPENCLAW_ENABLED"
  replace_token SYMPHONY_OPENCLAW_COMMAND "$SYMPHONY_OPENCLAW_COMMAND"
  replace_token SYMPHONY_OPENCLAW_CHANNEL "$SYMPHONY_OPENCLAW_CHANNEL"
  replace_token SYMPHONY_OPENCLAW_ACCOUNT "$SYMPHONY_OPENCLAW_ACCOUNT"
  replace_token SYMPHONY_OPENCLAW_TARGET "$SYMPHONY_OPENCLAW_TARGET"
  replace_token SYMPHONY_OPENCLAW_TIMEOUT_MS "$SYMPHONY_OPENCLAW_TIMEOUT_MS"
  replace_token SYMPHONY_OPENCLAW_INTAKE_ENABLED "$SYMPHONY_OPENCLAW_INTAKE_ENABLED"
  replace_token SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV"
  replace_token SYMPHONY_OPENCLAW_INTAKE_LABELS "$SYMPHONY_OPENCLAW_INTAKE_LABELS"
  replace_token SYMPHONY_OPENCLAW_EVENTS "$SYMPHONY_OPENCLAW_EVENTS"
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

required_env "$SYMPHONY_TRACKER_API_KEY_ENV"
if [[ -z "$SYMPHONY_TRACKER_PROJECT" ]]; then
  echo "SYMPHONY_TRACKER_PROJECT is required in $ENV_FILE for tracker kind $SYMPHONY_TRACKER_KIND" >&2
  exit 1
fi
required_env SYMPHONY_SOURCE_REPO_URL
validate_sandbox_requirements
validate_evidence_requirements

case "$SYMPHONY_OPENCLAW_ENABLED" in
  true|false)
    ;;
  *)
    echo "Invalid SYMPHONY_OPENCLAW_ENABLED=$SYMPHONY_OPENCLAW_ENABLED. Use true or false." >&2
    exit 1
    ;;
esac

if [[ "$SYMPHONY_OPENCLAW_ENABLED" == "true" && -z "$SYMPHONY_OPENCLAW_TARGET" ]]; then
  echo "SYMPHONY_OPENCLAW_TARGET is required when SYMPHONY_OPENCLAW_ENABLED=true" >&2
  exit 1
fi

case "$SYMPHONY_OPENCLAW_INTAKE_ENABLED" in
  true|false)
    ;;
  *)
    echo "Invalid SYMPHONY_OPENCLAW_INTAKE_ENABLED=$SYMPHONY_OPENCLAW_INTAKE_ENABLED. Use true or false." >&2
    exit 1
    ;;
esac

if [[ "$SYMPHONY_OPENCLAW_INTAKE_ENABLED" == "true" ]]; then
  if [[ "$SYMPHONY_TRACKER_KIND" != "github" ]]; then
    echo "SYMPHONY_OPENCLAW_INTAKE_ENABLED=true requires SYMPHONY_TRACKER_KIND=github" >&2
    exit 1
  fi

  required_env "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV"
fi

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

export "$SYMPHONY_TRACKER_API_KEY_ENV"
if [[ "$SYMPHONY_OPENCLAW_INTAKE_ENABLED" == "true" ]]; then
  export "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV"
fi
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
