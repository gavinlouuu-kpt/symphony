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

has_config_value() {
  local value=${1:-}
  local compact
  compact=$(printf '%s' "$value" | tr -d '[:space:]')
  [[ -n "$compact" && "$compact" != "[]" && "$compact" != "''" && "$compact" != '""' ]]
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
SYMPHONY_CUA_SSH_KEYGEN=${SYMPHONY_CUA_SSH_KEYGEN:-auto}
SYMPHONY_CUA_SSH_IDENTITY_FILE=${SYMPHONY_CUA_SSH_IDENTITY_FILE:-"$SYMPHONY_INSTANCE_ROOT/ssh/id_ed25519"}
SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH=${SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH:-"$SYMPHONY_CUA_SSH_IDENTITY_FILE.pub"}
SYMPHONY_OPENCLAW_ENABLED=${SYMPHONY_OPENCLAW_ENABLED:-false}
SYMPHONY_OPENCLAW_COMMAND=${SYMPHONY_OPENCLAW_COMMAND:-openclaw}
SYMPHONY_OPENCLAW_CHANNEL=${SYMPHONY_OPENCLAW_CHANNEL:-discord}
SYMPHONY_OPENCLAW_TARGET=${SYMPHONY_OPENCLAW_TARGET:-}
SYMPHONY_OPENCLAW_INTAKE_ENABLED=${SYMPHONY_OPENCLAW_INTAKE_ENABLED:-false}
SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV=${SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV:-SYMPHONY_OPENCLAW_INTAKE_TOKEN}
SYMPHONY_OPENCLAW_INTAKE_URL=${SYMPHONY_OPENCLAW_INTAKE_URL:-"http://127.0.0.1:$SYMPHONY_DASHBOARD_PORT/api/v1/openclaw/issues"}
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
SYMPHONY_TRACKER_KIND=${SYMPHONY_TRACKER_KIND:-linear}
case "$SYMPHONY_TRACKER_KIND" in
  github)
    SYMPHONY_TRACKER_API_KEY_ENV=${SYMPHONY_TRACKER_API_KEY_ENV:-GITHUB_TOKEN}
    SYMPHONY_TRACKER_PROJECT=${SYMPHONY_TRACKER_PROJECT:-${SYMPHONY_GITHUB_REPOSITORY:-}}
    ;;
  linear)
    SYMPHONY_TRACKER_API_KEY_ENV=${SYMPHONY_TRACKER_API_KEY_ENV:-LINEAR_API_KEY}
    SYMPHONY_TRACKER_PROJECT=${SYMPHONY_TRACKER_PROJECT:-${SYMPHONY_LINEAR_PROJECT_SLUG:-}}
    ;;
  *)
    check_fail "invalid SYMPHONY_TRACKER_KIND=$SYMPHONY_TRACKER_KIND"
    SYMPHONY_TRACKER_API_KEY_ENV=${SYMPHONY_TRACKER_API_KEY_ENV:-}
    SYMPHONY_TRACKER_PROJECT=${SYMPHONY_TRACKER_PROJECT:-}
    ;;
esac

if [[ -n "$SYMPHONY_TRACKER_API_KEY_ENV" && -n "${!SYMPHONY_TRACKER_API_KEY_ENV:-}" ]]; then
  check_ok "$SYMPHONY_TRACKER_API_KEY_ENV is set"
else
  check_fail "$SYMPHONY_TRACKER_API_KEY_ENV is missing"
fi

[[ -n "$SYMPHONY_TRACKER_PROJECT" ]] && check_ok "tracker project is set: $SYMPHONY_TRACKER_PROJECT" || check_fail "tracker project is missing"
[[ -n "${SYMPHONY_SOURCE_REPO_URL:-}" ]] && check_ok "SYMPHONY_SOURCE_REPO_URL is set" || check_fail "SYMPHONY_SOURCE_REPO_URL is missing"

case "$SYMPHONY_SANDBOX_CONTRACT_ENFORCED" in
  true)
    check_ok "sandbox contract enforcement enabled"

    case "$SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED" in
      true)
        check_ok "sandbox requirements audit marked complete"
        ;;
      false)
        check_fail "sandbox requirements audit is not complete; review repo docs/CI and set SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=true"
        ;;
      *)
        check_fail "invalid SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=$SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED"
        ;;
    esac

    if has_config_value "$SYMPHONY_SANDBOX_REQUIRED_COMMANDS"; then
      check_ok "sandbox required command list declared"
    else
      check_warn "SYMPHONY_SANDBOX_REQUIRED_COMMANDS is empty"
    fi

    if has_config_value "$SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES"; then
      check_ok "sandbox required Python module list declared"
    else
      check_warn "SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES is empty"
    fi

    if has_config_value "$SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES"; then
      check_ok "sandbox required system package list declared"
    else
      check_warn "SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES is empty"
    fi

    if has_config_value "$SYMPHONY_AFTER_CREATE_EXTRA"; then
      check_ok "sandbox bootstrap command declared"
    else
      check_warn "SYMPHONY_AFTER_CREATE_EXTRA is empty; base image must already contain routine dependencies"
    fi

    if has_config_value "$SYMPHONY_SANDBOX_BOOTSTRAP_CHECK"; then
      check_ok "sandbox bootstrap smoke check declared"
    else
      check_fail "SYMPHONY_SANDBOX_BOOTSTRAP_CHECK is required when sandbox contract enforcement is enabled"
    fi

    if ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_COMMANDS" \
      && ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES" \
      && ! has_config_value "$SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES" \
      && ! has_config_value "$SYMPHONY_SANDBOX_REQUIREMENTS_NOTES"; then
      check_fail "declare at least one sandbox requirement or note after audit"
    fi
    ;;
  false)
    check_warn "sandbox contract enforcement disabled; issue workspaces may miss project validation dependencies"
    ;;
  *)
    check_fail "invalid SYMPHONY_SANDBOX_CONTRACT_ENFORCED=$SYMPHONY_SANDBOX_CONTRACT_ENFORCED"
    ;;
esac

case "$SYMPHONY_EVIDENCE_CONTRACT_ENFORCED" in
  true)
    check_ok "evidence contract enforcement enabled"

    case "$SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED" in
      true)
        check_ok "evidence requirements audit marked complete"
        ;;
      false)
        check_fail "evidence requirements audit is not complete; set SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=true after declaring runtime/demo evidence requirements"
        ;;
      *)
        check_fail "invalid SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=$SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED"
        ;;
    esac

    if has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_CHECKS"; then
      check_ok "evidence required check list declared"
    else
      check_warn "SYMPHONY_EVIDENCE_REQUIRED_CHECKS is empty"
    fi

    if has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS"; then
      check_ok "evidence required artifact list declared"
    else
      check_warn "SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS is empty"
    fi

    if has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_COMMANDS"; then
      check_ok "evidence required command list declared"
    else
      check_warn "SYMPHONY_EVIDENCE_REQUIRED_COMMANDS is empty"
    fi

    if ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_CHECKS" \
      && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS" \
      && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIRED_COMMANDS" \
      && ! has_config_value "$SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES"; then
      check_fail "declare at least one evidence requirement or note after audit"
    fi
    ;;
  false)
    check_warn "evidence contract enforcement disabled; role agents may overclaim runtime/demo readiness"
    ;;
  *)
    check_fail "invalid SYMPHONY_EVIDENCE_CONTRACT_ENFORCED=$SYMPHONY_EVIDENCE_CONTRACT_ENFORCED"
    ;;
esac

[[ -d "$SYMPHONY_CODE_DIR/elixir" ]] && check_ok "Symphony checkout found" || check_fail "Symphony checkout missing at $SYMPHONY_CODE_DIR"
[[ -f "$SYMPHONY_INSTANCE_ROOT/WORKFLOW.md.template" ]] && check_ok "workflow template found" || check_fail "workflow template missing"

case "$SYMPHONY_CUA_SSH_KEYGEN" in
  auto)
    if [[ -s "$SYMPHONY_CUA_SSH_IDENTITY_FILE" && -s "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH" ]]; then
      check_ok "CUA SSH keypair exists"
    elif command -v ssh-keygen >/dev/null 2>&1; then
      check_warn "CUA SSH keypair missing; bin/start.sh will generate it"
    else
      check_fail "CUA SSH keypair missing and ssh-keygen is unavailable"
    fi
    ;;
  never)
    [[ -s "$SYMPHONY_CUA_SSH_IDENTITY_FILE" ]] && check_ok "CUA SSH identity file exists" || check_fail "CUA SSH identity file missing: $SYMPHONY_CUA_SSH_IDENTITY_FILE"
    [[ -s "$SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH" ]] && check_ok "CUA SSH authorized key exists" || check_fail "CUA SSH authorized key missing: $SYMPHONY_CUA_SSH_AUTHORIZED_KEY_PATH"
    ;;
  *)
    check_fail "invalid SYMPHONY_CUA_SSH_KEYGEN=$SYMPHONY_CUA_SSH_KEYGEN"
    ;;
esac

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

case "$SYMPHONY_OPENCLAW_ENABLED" in
  true)
    read -r -a OPENCLAW_CMD_PARTS <<< "$SYMPHONY_OPENCLAW_COMMAND"
    OPENCLAW_EXECUTABLE=${OPENCLAW_CMD_PARTS[0]:-}

    [[ -n "$SYMPHONY_OPENCLAW_CHANNEL" ]] && check_ok "OpenClaw channel is set: $SYMPHONY_OPENCLAW_CHANNEL" || check_fail "OpenClaw channel is missing"
    [[ -n "$SYMPHONY_OPENCLAW_TARGET" ]] && check_ok "OpenClaw target is set: $SYMPHONY_OPENCLAW_TARGET" || check_fail "OpenClaw target is missing"

    if [[ -n "$OPENCLAW_EXECUTABLE" ]] && command -v "$OPENCLAW_EXECUTABLE" >/dev/null 2>&1; then
      check_ok "OpenClaw command found: $OPENCLAW_EXECUTABLE"
    else
      check_fail "OpenClaw command not found: $SYMPHONY_OPENCLAW_COMMAND"
    fi
    ;;
  false)
    check_warn "OpenClaw channel bridge disabled; set SYMPHONY_OPENCLAW_ENABLED=true to publish to Discord or another OpenClaw channel"
    ;;
  *)
    check_fail "invalid SYMPHONY_OPENCLAW_ENABLED=$SYMPHONY_OPENCLAW_ENABLED"
    ;;
esac

case "$SYMPHONY_OPENCLAW_INTAKE_ENABLED" in
  true)
    if [[ "$SYMPHONY_TRACKER_KIND" == "github" ]]; then
      check_ok "OpenClaw issue intake is using GitHub tracker mode"
    else
      check_fail "OpenClaw issue intake requires SYMPHONY_TRACKER_KIND=github"
    fi

    if [[ -n "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV" && -n "${!SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV:-}" ]]; then
      check_ok "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV is set"
    else
      check_fail "$SYMPHONY_OPENCLAW_INTAKE_TOKEN_ENV is missing"
    fi

    check_ok "OpenClaw issue intake URL: $SYMPHONY_OPENCLAW_INTAKE_URL"
    ;;
  false)
    check_warn "OpenClaw issue intake disabled; set SYMPHONY_OPENCLAW_INTAKE_ENABLED=true to create GitHub issues from chat"
    ;;
  *)
    check_fail "invalid SYMPHONY_OPENCLAW_INTAKE_ENABLED=$SYMPHONY_OPENCLAW_INTAKE_ENABLED"
    ;;
esac

if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$SYMPHONY_DASHBOARD_PORT )" | tail -n +2 | grep -q .; then
    check_warn "dashboard port appears in use: $SYMPHONY_DASHBOARD_PORT"
  else
    check_ok "dashboard port appears available: $SYMPHONY_DASHBOARD_PORT"
  fi
else
  check_warn "ss not found; skipped dashboard port check"
fi

if [[ "${SYMPHONY_DOCTOR_ONLINE:-0}" == "1" && -n "$SYMPHONY_TRACKER_API_KEY_ENV" && -n "${!SYMPHONY_TRACKER_API_KEY_ENV:-}" ]]; then
  case "$SYMPHONY_TRACKER_KIND" in
    github)
      if curl -fsS \
        -H "Authorization: Bearer ${!SYMPHONY_TRACKER_API_KEY_ENV}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$SYMPHONY_TRACKER_PROJECT" \
        | grep -q '"full_name"'; then
        check_ok "GitHub API reachable"
      else
        check_fail "GitHub API check failed"
      fi
      ;;
    linear)
      if curl -fsS \
        -H "Authorization: ${!SYMPHONY_TRACKER_API_KEY_ENV}" \
        -H "Content-Type: application/json" \
        https://api.linear.app/graphql \
        --data-binary '{"query":"query Viewer { viewer { id } }"}' \
        | grep -q '"viewer"'; then
        check_ok "Linear API reachable"
      else
        check_fail "Linear API check failed"
      fi
      ;;
  esac
else
  check_warn "skipped tracker online check; set SYMPHONY_DOCTOR_ONLINE=1 to enable"
fi

if [[ "$FAILED" == "0" ]]; then
  check_ok "project template checks passed"
else
  exit 1
fi
