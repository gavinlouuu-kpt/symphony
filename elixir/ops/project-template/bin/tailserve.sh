#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTANCE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE=${SYMPHONY_ENV_FILE:-"$INSTANCE_ROOT/symphony.env"}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

SYMPHONY_INSTANCE_ID=${SYMPHONY_INSTANCE_ID:-$(basename "$INSTANCE_ROOT")}
SYMPHONY_DASHBOARD_HOST=${SYMPHONY_DASHBOARD_HOST:-127.0.0.1}
SYMPHONY_DASHBOARD_PORT=${SYMPHONY_DASHBOARD_PORT:-4401}
SYMPHONY_TAILSERVE_HTTPS_PORT=${SYMPHONY_TAILSERVE_HTTPS_PORT:-443}
SYMPHONY_TAILSERVE_LOCAL_HOST=${SYMPHONY_TAILSERVE_LOCAL_HOST:-$SYMPHONY_DASHBOARD_HOST}

sanitize_service_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

tailnet_suffix() {
  tailscale status --json 2>/dev/null \
    | jq -r '.MagicDNSSuffix // (.Self.DNSName // "" | sub("^[^.]+\\."; "") | sub("\\.$"; ""))'
}

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale command not found; install Tailscale or set SYMPHONY_TAILSERVE_ENABLED=false." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq command not found; install jq to derive the Tailscale DNS suffix." >&2
  exit 1
fi

DEFAULT_SERVICE="symphony-$(sanitize_service_name "$SYMPHONY_INSTANCE_ID")"
SERVICE_NAME=${SYMPHONY_TAILSERVE_SERVICE:-$DEFAULT_SERVICE}
SERVICE_NAME=$(sanitize_service_name "$SERVICE_NAME")

if [[ -z "$SERVICE_NAME" ]]; then
  echo "Unable to derive a valid Tailscale service name from SYMPHONY_INSTANCE_ID=$SYMPHONY_INSTANCE_ID" >&2
  exit 1
fi

SUFFIX=${SYMPHONY_TAILSERVE_DNS_SUFFIX:-$(tailnet_suffix)}
if [[ -z "$SUFFIX" || "$SUFFIX" == "null" ]]; then
  echo "Unable to derive Tailscale DNS suffix. Is this node logged in to Tailscale?" >&2
  exit 1
fi

TARGET="http://${SYMPHONY_TAILSERVE_LOCAL_HOST}:${SYMPHONY_DASHBOARD_PORT}"
URL="https://${SERVICE_NAME}.${SUFFIX}/"

echo "Configuring Tailscale Serve for Symphony instance:"
echo "  service: svc:${SERVICE_NAME}"
echo "  target:  ${TARGET}"
echo "  url:     ${URL}"

tailscale serve \
  --service="svc:${SERVICE_NAME}" \
  --yes \
  --bg \
  --https="${SYMPHONY_TAILSERVE_HTTPS_PORT}" \
  "$TARGET"

mkdir -p "$INSTANCE_ROOT/runtime"
{
  printf 'SYMPHONY_TAILSERVE_SERVICE=%q\n' "$SERVICE_NAME"
  printf 'SYMPHONY_TAILSERVE_URL=%q\n' "$URL"
  printf 'SYMPHONY_TAILSERVE_TARGET=%q\n' "$TARGET"
} >"$INSTANCE_ROOT/runtime/tailserve.env"

echo
echo "Saved runtime/tailserve.env"
echo "Open: $URL"
