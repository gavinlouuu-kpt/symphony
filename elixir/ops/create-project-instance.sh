#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_DIR=${SYMPHONY_PROJECT_TEMPLATE_DIR:-"$SCRIPT_DIR/project-template"}

usage() {
  cat <<'EOF'
Usage: ops/create-project-instance.sh <instance-id> [instance-root]

Creates a reusable one-project Symphony CUA instance directory.

Examples:
  ops/create-project-instance.sh biowork
  ops/create-project-instance.sh mib-studio-qt /home/gavin/Service/symphony/mib-studio-qt

Environment:
  SYMPHONY_DASHBOARD_PORT  Optional initial dashboard port written to symphony.env.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit $([[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && echo 0 || echo 1)
fi

INSTANCE_ID=$1
INSTANCE_ROOT=${2:-"/home/gavin/Service/symphony/$INSTANCE_ID"}
DASHBOARD_PORT=${SYMPHONY_DASHBOARD_PORT:-4401}

if [[ ! "$INSTANCE_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Instance id may only contain letters, numbers, dot, underscore, and dash." >&2
  exit 1
fi

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  echo "Template directory not found: $TEMPLATE_DIR" >&2
  exit 1
fi

mkdir -p "$INSTANCE_ROOT"
cp -R "$TEMPLATE_DIR"/. "$INSTANCE_ROOT"/

if [[ ! -f "$INSTANCE_ROOT/symphony.env" ]]; then
  cp "$INSTANCE_ROOT/symphony.env.example" "$INSTANCE_ROOT/symphony.env"
fi

replace_in_env() {
  local key=$1
  local value=$2
  local escaped
  escaped=${value//\\/\\\\}
  escaped=${escaped//&/\\&}
  escaped=${escaped//|/\\|}
  sed -i "s|$key|$escaped|g" "$INSTANCE_ROOT/symphony.env"
}

replace_in_env "example-project" "$INSTANCE_ID"
replace_in_env "/home/gavin/Service/symphony/$INSTANCE_ID" "$INSTANCE_ROOT"
sed -i "s|^SYMPHONY_DASHBOARD_PORT=.*|SYMPHONY_DASHBOARD_PORT=$DASHBOARD_PORT|" "$INSTANCE_ROOT/symphony.env"
sed -i "s|^SYMPHONY_TAILSERVE_SERVICE=.*|SYMPHONY_TAILSERVE_SERVICE=symphony-$INSTANCE_ID|" "$INSTANCE_ROOT/symphony.env"

chmod +x "$INSTANCE_ROOT"/bin/*.sh

cat <<EOF
Created Symphony project instance:
  $INSTANCE_ROOT

Next:
  1. Edit $INSTANCE_ROOT/symphony.env
  2. Set LINEAR_API_KEY, SYMPHONY_LINEAR_PROJECT_SLUG, and SYMPHONY_SOURCE_REPO_URL
  3. Run: cd "$INSTANCE_ROOT" && bin/doctor.sh
  4. Run: cd "$INSTANCE_ROOT" && bin/start.sh
  5. Optional stable Tailscale URL: cd "$INSTANCE_ROOT" && bin/tailserve.sh
EOF
