#!/usr/bin/env bash
# Boots the virtual desktop stack for a per-issue Symphony agent container:
# Xvfb (virtual display) -> openbox (window manager) -> x11vnc (VNC server)
# -> websockify/noVNC (browser access on port 6080).
set -euo pipefail

DISPLAY_NUM="${SYMPHONY_DISPLAY:-:1}"
GEOMETRY="${SYMPHONY_DESKTOP_GEOMETRY:-1440x900x24}"
VNC_PORT="${SYMPHONY_VNC_PORT:-5900}"
NOVNC_PORT="${SYMPHONY_NOVNC_PORT:-6080}"
WORKSPACE_DIR="${SYMPHONY_WORKSPACE_DIR:-/workspace}"
LOG_FILE="${SYMPHONY_DESKTOP_LOG:-/var/log/symphony-agent-desktop.log}"

# Mirror the desktop stack's output to a log file so the container
# orchestrator's debug phase can surface recent desktop logs.
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

export DISPLAY="$DISPLAY_NUM"

Xvfb "$DISPLAY_NUM" -screen 0 "$GEOMETRY" -nolisten tcp &

for _ in $(seq 1 50); do
  if xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

openbox &

# An interactive terminal in the agent workspace so operators watching the
# desktop can inspect (or nudge) the run, Cursor-style.
xterm \
  -title "Symphony agent workspace" \
  -fa DejaVuSansMono -fs 11 \
  -geometry 150x40+24+24 \
  -e "cd '$WORKSPACE_DIR' 2>/dev/null || cd /; exec bash" &

x11vnc -display "$DISPLAY_NUM" -rfbport "$VNC_PORT" -forever -shared -nopw -quiet &

exec websockify --web /usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT"
