#!/usr/bin/env bash
set -euo pipefail

# One-command onboarding of a GitHub repository into Symphony:
#   - creates a project instance dir from ops/project-template
#   - writes a complete symphony.env (GitHub tracker + OpenClaw/Discord bridge)
#   - ensures the `symphony` and `openclaw-intake` labels exist on the repo
#   - registers the Discord channel in the OpenClaw intake profiles (no gateway
#     restart needed; the intake hook re-reads profiles.json per message)
#   - enables and starts the systemd user unit symphony@<instance>
#   - waits for the orchestrator health endpoint and announces in the channel
#
# Designed to be safe for a chat-driven operator (e.g. the OpenClaw Discord
# agent): no secrets are taken from arguments; they come from the defaults file.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_DIR=${SYMPHONY_PROJECT_TEMPLATE_DIR:-"$SCRIPT_DIR/project-template"}
SERVICE_ROOT=${SYMPHONY_SERVICE_ROOT:-"$HOME/Service/symphony"}
DEFAULTS_FILE=${SYMPHONY_ONBOARD_DEFAULTS:-"$SERVICE_ROOT/onboard-defaults.env"}
PROFILES_FILE=${SYMPHONY_OPENCLAW_PROFILES_FILE:-"$HOME/.openclaw/symphony/profiles.json"}
OPENCLAW_BIN=${SYMPHONY_OPENCLAW_BIN:-"$HOME/.npm-global/bin/openclaw"}
CODE_DIR=${SYMPHONY_CODE_DIR:-"$(cd "$SCRIPT_DIR/../.." && pwd)"}

usage() {
  cat <<'EOF'
Usage: ops/onboard-github-project.sh <owner/repo> --discord-channel <channel-id> [options]

Options:
  --discord-channel <id>  Discord channel id for this project (required)
  --instance-id <name>    Instance name (default: repo name, lowercased)
  --port <port>           Dashboard/API port (default: next free port from 4404)
  --branch <branch>       Source branch (default: repository default branch)
  --model <model>         Codex model (default: gpt-5.4-mini)
  --effort <level>        Codex reasoning effort (default: medium)
  --host <ip>             Host/IP for dashboard + intake URL (default: from defaults file)
  --no-start              Provision everything but do not start the service
  -h, --help              Show this help

Secrets come from the defaults file (default: ~/Service/symphony/onboard-defaults.env),
which must define GITHUB_TOKEN (and may define GH_TOKEN, SYMPHONY_ONBOARD_HOST,
SYMPHONY_OPENCLAW_ACCOUNT).
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

REPO=""
DISCORD_CHANNEL=""
INSTANCE_ID=""
PORT=""
BRANCH=""
MODEL="gpt-5.4-mini"
EFFORT="medium"
HOST_OVERRIDE=""
START_SERVICE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --discord-channel) DISCORD_CHANNEL=${2:-}; shift 2 ;;
    --instance-id) INSTANCE_ID=${2:-}; shift 2 ;;
    --port) PORT=${2:-}; shift 2 ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    --model) MODEL=${2:-}; shift 2 ;;
    --effort) EFFORT=${2:-}; shift 2 ;;
    --host) HOST_OVERRIDE=${2:-}; shift 2 ;;
    --no-start) START_SERVICE=0; shift ;;
    -*) fail "Unknown option: $1" ;;
    *)
      [[ -n "$REPO" ]] && fail "Unexpected argument: $1"
      REPO=$1; shift ;;
  esac
done

[[ -n "$REPO" ]] || { usage; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "Repository must be owner/repo, got: $REPO"
[[ -n "$DISCORD_CHANNEL" ]] || fail "--discord-channel is required (the Discord channel id for this project)"
[[ "$DISCORD_CHANNEL" =~ ^[0-9]{5,}$ ]] || fail "--discord-channel must be a numeric Discord channel id"
[[ -f "$DEFAULTS_FILE" ]] || fail "Defaults file not found: $DEFAULTS_FILE"
[[ -f "$PROFILES_FILE" ]] || fail "OpenClaw intake profiles file not found: $PROFILES_FILE"
[[ -x "$OPENCLAW_BIN" ]] || fail "openclaw CLI not found at $OPENCLAW_BIN"
[[ -d "$TEMPLATE_DIR" ]] || fail "Template directory not found: $TEMPLATE_DIR"

# shellcheck source=/dev/null
source "$DEFAULTS_FILE"
[[ -n "${GITHUB_TOKEN:-}" ]] || fail "GITHUB_TOKEN missing in $DEFAULTS_FILE"
GH_TOKEN=${GH_TOKEN:-$GITHUB_TOKEN}
HOST=${HOST_OVERRIDE:-${SYMPHONY_ONBOARD_HOST:-127.0.0.1}}
OPENCLAW_ACCOUNT=${SYMPHONY_OPENCLAW_ACCOUNT:-}

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID=$(basename "$REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
fi
[[ "$INSTANCE_ID" =~ ^[a-zA-Z0-9._-]+$ ]] || fail "Invalid instance id: $INSTANCE_ID"

INSTANCE_ROOT="$SERVICE_ROOT/$INSTANCE_ID"
[[ -e "$INSTANCE_ROOT" ]] && fail "Instance directory already exists: $INSTANCE_ROOT (pick --instance-id or remove it first)"

github_api() {
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -m 30 -X "$method" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -w '\n%{http_code}')
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "https://api.github.com$path"
}

# Verify repo access and resolve the default branch.
REPO_RESPONSE=$(github_api GET "/repos/$REPO")
REPO_STATUS=$(tail -n1 <<<"$REPO_RESPONSE")
REPO_BODY=$(sed '$d' <<<"$REPO_RESPONSE")
[[ "$REPO_STATUS" == "200" ]] || fail "Cannot access repo $REPO (HTTP $REPO_STATUS). Check the token's access."

CAN_PUSH=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if (d.get("permissions") or {}).get("push") else "no")' <<<"$REPO_BODY")
[[ "$CAN_PUSH" == "yes" ]] || fail "Token lacks push access to $REPO; Symphony agents need push access."

if [[ -z "$BRANCH" ]]; then
  BRANCH=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("default_branch") or "main")' <<<"$REPO_BODY")
fi

# Pick a free port: not used by another instance env and not currently listening.
port_in_use() {
  local candidate=$1
  grep -rhsE "^(SYMPHONY_DASHBOARD_PORT|BIOWORK_SYMPHONY_PORT)=$candidate$" "$SERVICE_ROOT"/*/symphony.env 2>/dev/null | grep -q . && return 0
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$candidate$"
}

if [[ -z "$PORT" ]]; then
  for candidate in $(seq 4404 4499); do
    if ! port_in_use "$candidate"; then
      PORT=$candidate
      break
    fi
  done
fi
[[ -n "$PORT" ]] || fail "No free port found in 4404-4499"
port_in_use "$PORT" && fail "Port $PORT is already in use"

# Ensure routing labels exist on the repo.
ensure_label() {
  local name=$1 color=$2 description=$3
  local response status
  response=$(github_api POST "/repos/$REPO/labels" \
    "{\"name\":\"$name\",\"color\":\"$color\",\"description\":\"$description\"}")
  status=$(tail -n1 <<<"$response")
  case "$status" in
    201) echo "Created label $name" ;;
    422) echo "Label $name already exists" ;;
    *) fail "Failed to create label $name (HTTP $status)" ;;
  esac
}

ensure_label "symphony" "5319e7" "Managed by the Symphony orchestrator"
ensure_label "openclaw-intake" "0e8a16" "Active routing label: Symphony works this issue while present"

# Create the instance from the template.
"$SCRIPT_DIR/create-project-instance.sh" "$INSTANCE_ID" "$INSTANCE_ROOT" >/dev/null

INTAKE_TOKEN=$(openssl rand -hex 24)

CODEX_COMMAND="codex --config shell_environment_policy.inherit=all --config shell_environment_policy.exclude=[\\\"GH_TOKEN\\\",\\\"GITHUB_TOKEN\\\",\\\"LINEAR_API_KEY\\\",\\\"SYMPHONY_OPENCLAW_*\\\"] --config shell_environment_policy.set.GH_CONFIG_DIR=\\\"/tmp/symphony-no-host-gh\\\" --config model=\\\"$MODEL\\\" --config model_reasoning_effort=$EFFORT app-server"

umask 077
cat > "$INSTANCE_ROOT/symphony.env" <<EOF
# Generated by ops/onboard-github-project.sh on $(date -Is)
# Repo: $REPO  Discord channel: $DISCORD_CHANNEL

SYMPHONY_TRACKER_KIND=github
GITHUB_TOKEN=$GITHUB_TOKEN
GH_TOKEN=$GH_TOKEN
SYMPHONY_TRACKER_PROJECT=$REPO
SYMPHONY_SOURCE_REPO_URL=https://github.com/$REPO.git
SYMPHONY_SOURCE_REPO_BRANCH=$BRANCH

SYMPHONY_INSTANCE_ID=$INSTANCE_ID
SYMPHONY_CODE_DIR=$CODE_DIR
SYMPHONY_INSTANCE_ROOT=$INSTANCE_ROOT
SYMPHONY_RUNTIME_ROOT=$INSTANCE_ROOT/runtime
SYMPHONY_LOGS_ROOT=$INSTANCE_ROOT/log
SYMPHONY_EVIDENCE_ROOT=$INSTANCE_ROOT/evidence
SYMPHONY_WORKSPACE_ROOT=/home/cua/workspaces

SYMPHONY_DASHBOARD_HOST=$HOST
SYMPHONY_DASHBOARD_PORT=$PORT

SYMPHONY_POLL_INTERVAL_MS=15000
SYMPHONY_MAX_CONCURRENT_AGENTS=4
SYMPHONY_MAX_TURNS=20
SYMPHONY_UNROUTE_GRACE_MS=300000

SYMPHONY_OPENCLAW_ENABLED=true
SYMPHONY_OPENCLAW_COMMAND=$OPENCLAW_BIN
SYMPHONY_OPENCLAW_CHANNEL=discord
SYMPHONY_OPENCLAW_ACCOUNT=$OPENCLAW_ACCOUNT
SYMPHONY_OPENCLAW_TARGET=channel:$DISCORD_CHANNEL
SYMPHONY_OPENCLAW_TIMEOUT_MS=10000
SYMPHONY_OPENCLAW_INTAKE_ENABLED=true
SYMPHONY_OPENCLAW_INTAKE_TOKEN=$INTAKE_TOKEN

# Generic onboarding contracts: audited with baseline requirements so the
# instance can start immediately. Tighten per-repo after the first issues.
SYMPHONY_SANDBOX_CONTRACT_ENFORCED=true
SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=true
SYMPHONY_SANDBOX_REQUIRED_COMMANDS='["git", "gh"]'
SYMPHONY_SANDBOX_BOOTSTRAP_CHECK='git rev-parse HEAD >/dev/null 2>&1 && command -v gh >/dev/null 2>&1'
SYMPHONY_SANDBOX_REQUIREMENTS_NOTES='Baseline onboarding contract (git + gh). Audit the repo docs/CI and tighten required commands, modules, packages, and the bootstrap check. Container engines (docker/compose) are not available inside issue sandboxes by design: validate with in-sandbox dev servers, builds, and the sandbox browser instead of compose targets.'

SYMPHONY_EVIDENCE_CONTRACT_ENFORCED=true
SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=true
SYMPHONY_EVIDENCE_REQUIRED_CHECKS='["evaluator handoff evidence review", "local runtime validation"]'
SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS='[".symphony/artifacts/handoff-evidence.md", ".symphony/artifacts/local-validation.md"]'
SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES='Both checks must link real commands/transcripts and artifacts produced during the current issue cycle. local runtime validation must actually exercise the changed behavior inside the sandbox (dev server/build + browser pass for UI work); mocks, CI-only checks, or stale screenshots are not sufficient, and "live validation blocked" is not an accepted handoff state.'

SYMPHONY_CUA_HOST=$HOST
SYMPHONY_CUA_IMAGE=symphony-cua-worker:latest
SYMPHONY_CUA_NAME_PREFIX=$INSTANCE_ID-symphony
SYMPHONY_CUA_DELETE_ON_TERMINAL=true

SYMPHONY_CODEX_COMMAND='$CODEX_COMMAND'
EOF

chmod 600 "$INSTANCE_ROOT/symphony.env"

# Render-only pass to validate the configuration before touching systemd.
SYMPHONY_RENDER_ONLY=1 SYMPHONY_ENV_FILE="$INSTANCE_ROOT/symphony.env" "$INSTANCE_ROOT/bin/start.sh" >/dev/null ||
  fail "Workflow render/validation failed; inspect $INSTANCE_ROOT/symphony.env"

# Register the intake profile (hot-reloaded per message; no gateway restart).
python3 - "$PROFILES_FILE" "$INSTANCE_ID" "$DISCORD_CHANNEL" "http://$HOST:$PORT/api/v1/openclaw/issues" "$INTAKE_TOKEN" <<'PYEOF'
import json, os, sys, tempfile

path, instance, channel, url, token = sys.argv[1:6]
with open(path) as f:
    config = json.load(f)

config.setdefault("channels", {})
config.setdefault("profiles", {})

existing = config["channels"].get(channel)
if existing and existing != instance:
    sys.exit(f"Discord channel {channel} is already mapped to profile {existing}")

config["channels"][channel] = instance
config["profiles"][instance] = {
    "url": url,
    "token": token,
    "channel": "discord",
    "target": f"channel:{channel}",
    "labels": ["openclaw-intake"],
}

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".profiles-")
with os.fdopen(fd, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"Registered intake profile {instance} for channel {channel}")
PYEOF

if [[ "$START_SERVICE" == "0" ]]; then
  cat <<EOF
Provisioned (not started):
  Instance: $INSTANCE_ID
  Root:     $INSTANCE_ROOT
  Port:     $PORT
Start with: systemctl --user enable --now symphony@$INSTANCE_ID.service
EOF
  exit 0
fi

systemctl --user enable --now "symphony@$INSTANCE_ID.service"

echo "Waiting for orchestrator health on port $PORT (first start builds the escript)..."
HEALTH_OK=0
for _ in $(seq 1 60); do
  sleep 5
  if curl -s -m 3 "http://$HOST:$PORT/api/v1/state" | grep -q '"counts"'; then
    HEALTH_OK=1
    break
  fi

  if ! systemctl --user is-active --quiet "symphony@$INSTANCE_ID.service"; then
    journalctl --user -u "symphony@$INSTANCE_ID.service" --no-pager -n 20 >&2 || true
    fail "symphony@$INSTANCE_ID.service is not active; see journal above"
  fi
done
[[ "$HEALTH_OK" == "1" ]] || fail "Orchestrator did not become healthy within 5 minutes"

"$OPENCLAW_BIN" message send --channel discord \
  ${OPENCLAW_ACCOUNT:+--account "$OPENCLAW_ACCOUNT"} \
  --target "channel:$DISCORD_CHANNEL" \
  --message "Symphony is now watching $REPO (branch $BRANCH). File work with \`issue <title/description>\` in this channel; each issue gets its own thread with live status, workpad updates, and visual evidence. Dashboard: http://$HOST:$PORT" \
  >/dev/null 2>&1 || echo "WARNING: could not post the announcement to Discord channel $DISCORD_CHANNEL" >&2

cat <<EOF
Symphony onboarded $REPO
  Instance:   $INSTANCE_ID
  Root:       $INSTANCE_ROOT
  Service:    symphony@$INSTANCE_ID.service
  Dashboard:  http://$HOST:$PORT
  Discord:    channel $DISCORD_CHANNEL (intake trigger: "issue ...")
  Branch:     $BRANCH
  Labels:     symphony + openclaw-intake (routing safeguards active)
EOF
