#!/bin/sh
set -eu

install -d -m 700 -o cua -g cua /home/cua/.ssh /home/cua/.codex
install -d -m 755 /var/run/sshd
install -d -m 755 /etc/ssh/sshd_config.d

printf '%s\n' 'PermitUserEnvironment GITHUB_TOKEN,GH_TOKEN' \
  > /etc/ssh/sshd_config.d/symphony-env.conf

env_tmp="$(mktemp)"
for env_name in GITHUB_TOKEN GH_TOKEN; do
  env_value="$(printenv "$env_name" || true)"
  if [ -n "$env_value" ]; then
    printf '%s=%s\n' "$env_name" "$env_value" >> "$env_tmp"
  fi
done

if [ -s "$env_tmp" ]; then
  install -m 600 -o cua -g cua "$env_tmp" /home/cua/.ssh/environment
else
  rm -f /home/cua/.ssh/environment
fi
rm -f "$env_tmp"

if [ -s /run/symphony/ssh/authorized_key.pub ]; then
  install -m 600 -o cua -g cua /run/symphony/ssh/authorized_key.pub /home/cua/.ssh/authorized_keys
fi

if [ -s /run/symphony/codex/auth.json ]; then
  install -m 600 -o cua -g cua /run/symphony/codex/auth.json /home/cua/.codex/auth.json
fi

if [ -s /run/symphony/codex/config.toml ]; then
  install -m 600 -o cua -g cua /run/symphony/codex/config.toml /home/cua/.codex/config.toml
fi

exec /usr/sbin/sshd -D -e
