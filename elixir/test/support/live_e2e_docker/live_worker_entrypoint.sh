#!/bin/sh
set -eu

install -d -m 700 /root/.ssh /root/.codex /run/symphony/codex

if [ ! -s /run/symphony/ssh/authorized_key.pub ]; then
  echo "missing authorized key at /run/symphony/ssh/authorized_key.pub" >&2
  exit 1
fi

install -m 600 /run/symphony/ssh/authorized_key.pub /root/.ssh/authorized_keys

if [ -s /run/symphony/codex/config.toml ]; then
  install -m 600 /run/symphony/codex/config.toml /root/.codex/config.toml
fi

case "${SYMPHONY_LIVE_WORKER_SSH_PORT:-}" in
  "")
    ;;
  *[!0-9]*)
    echo "invalid SYMPHONY_LIVE_WORKER_SSH_PORT: ${SYMPHONY_LIVE_WORKER_SSH_PORT}" >&2
    exit 1
    ;;
  *)
    printf 'Port %s\n' "$SYMPHONY_LIVE_WORKER_SSH_PORT" > /etc/ssh/sshd_config.d/symphony-live-worker-port.conf
    ;;
esac

exec /usr/sbin/sshd -D -e
