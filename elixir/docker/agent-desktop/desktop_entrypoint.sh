#!/usr/bin/env bash
# Boots the virtual desktop stack for a per-issue Symphony agent container:
# Xvfb (virtual display) -> openbox (window manager) -> x11vnc (VNC server)
# -> websockify/noVNC (browser access on port 6080). When recording is enabled
# an ffmpeg screen grab of the virtual display is captured into the workspace so
# the run can be replayed for demo and review.
set -euo pipefail

DISPLAY_NUM="${SYMPHONY_DISPLAY:-:1}"
GEOMETRY="${SYMPHONY_DESKTOP_GEOMETRY:-1440x900x24}"
VNC_PORT="${SYMPHONY_VNC_PORT:-5900}"
NOVNC_PORT="${SYMPHONY_NOVNC_PORT:-6080}"
WORKSPACE_DIR="${SYMPHONY_WORKSPACE_DIR:-/workspace}"
LOG_FILE="${SYMPHONY_DESKTOP_LOG:-/var/log/symphony-agent-desktop.log}"
RECORD="${SYMPHONY_DESKTOP_RECORD:-0}"
RECORDINGS_DIR="${SYMPHONY_RECORDINGS_DIR:-$WORKSPACE_DIR/.symphony/recordings}"
RECORD_FRAMERATE="${SYMPHONY_RECORD_FRAMERATE:-10}"
RECORD_SEGMENT_SECONDS="${SYMPHONY_RECORD_SEGMENT_SECONDS:-60}"

# Mirror the desktop stack's output to a log file so the container
# orchestrator's debug phase can surface recent desktop logs.
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

export DISPLAY="$DISPLAY_NUM"

# Records the virtual display into the (bind-mounted) workspace so operators can
# review the run later. Segmented output keeps already-written chunks playable
# even when the container is force-removed (SIGKILL) at cleanup time.
start_recording() {
  case "$RECORD" in
    1 | true | TRUE | yes) ;;
    *) return 0 ;;
  esac

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "symphony-agent-desktop: ffmpeg not found; desktop recording disabled" >&2
    return 0
  fi

  # Xvfb geometry is WIDTHxHEIGHTxDEPTH; ffmpeg's x11grab wants WIDTHxHEIGHT.
  local video_size="${GEOMETRY%x*}"

  mkdir -p "$RECORDINGS_DIR"
  echo "symphony-agent-desktop: recording desktop to $RECORDINGS_DIR (${video_size} @ ${RECORD_FRAMERATE}fps, ${RECORD_SEGMENT_SECONDS}s segments)"

  ffmpeg -nostdin -loglevel error \
    -f x11grab -framerate "$RECORD_FRAMERATE" -video_size "$video_size" -i "$DISPLAY_NUM" \
    -codec:v libx264 -preset veryfast -pix_fmt yuv420p -g "$((RECORD_FRAMERATE * 2))" \
    -f segment -segment_time "$RECORD_SEGMENT_SECONDS" -reset_timestamps 1 -strftime 1 \
    "$RECORDINGS_DIR/desktop-%Y%m%d-%H%M%S.mp4" &
}

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

start_recording

x11vnc -display "$DISPLAY_NUM" -rfbport "$VNC_PORT" -forever -shared -nopw -quiet &

exec websockify --web /usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT"
