#!/bin/sh
set -eu

install -d -m 700 -o cua -g cua /home/cua/.ssh /home/cua/.codex
install -d -m 755 /var/run/sshd

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
