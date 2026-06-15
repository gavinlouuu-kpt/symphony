# Symphony Agent Desktop Image

Container image for Symphony's per-issue agent containers. Each running issue
gets one container built from this image, with:

- The Codex CLI (`codex app-server` is spawned inside the container via
  `docker exec` by the orchestrator).
- A virtual desktop (Xvfb + openbox + xterm) where GUI tools launched by the
  agent appear, plus an interactive terminal opened in the issue workspace.
- A noVNC endpoint on container port `6080` so the Symphony web dashboard can
  embed a fully interactive view of the desktop.
- Optional desktop recording (`ffmpeg` screen grab) that captures the virtual
  display into the workspace so each run can be replayed for demo and review.

## Build

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Enable in WORKFLOW.md

```yaml
container:
  enabled: true
  image: symphony-agent-desktop:latest
```

Codex inside the container needs credentials. Symphony copies the host's
`~/.codex/auth.json` (configurable via `container.codex_auth_file`) into each
fresh container at `/root/.codex/auth.json`, so no extra configuration is
needed when the orchestrator host is logged in to Codex. Do not bind-mount
`auth.json` instead — Codex rewrites the file when it refreshes its OAuth
tokens, so mounted credentials break after the first refresh. See
`../../docs/containers.md` for details.

The orchestrator bind-mounts each issue workspace at `/workspace` inside the
container and publishes the noVNC port on an ephemeral host port (bound to
`127.0.0.1` by default). The dashboard's "Agent desktops" section picks the
URL up automatically.

## Security notes

- The noVNC endpoint is unauthenticated; it is only published on
  `container.novnc_host` (default `127.0.0.1`). If you change that to a
  routable address, put an authenticating proxy in front of it.
- Anyone with access to the dashboard can interact with the agent's desktop
  and workspace.

## Environment overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `SYMPHONY_DISPLAY` | `:1` | X display number |
| `SYMPHONY_DESKTOP_GEOMETRY` | `1440x900x24` | Virtual screen geometry |
| `SYMPHONY_VNC_PORT` | `5900` | In-container VNC port |
| `SYMPHONY_NOVNC_PORT` | `6080` | In-container noVNC (websocket) port |
| `SYMPHONY_WORKSPACE_DIR` | `/workspace` | Directory the desktop terminal opens in |
| `SYMPHONY_DESKTOP_RECORD` | `0` | Set to `1`/`true` to record the desktop with ffmpeg |
| `SYMPHONY_RECORDINGS_DIR` | `$SYMPHONY_WORKSPACE_DIR/.symphony/recordings` | Where recording segments are written |
| `SYMPHONY_RECORD_FRAMERATE` | `10` | Recording frame rate (fps) |
| `SYMPHONY_RECORD_SEGMENT_SECONDS` | `60` | Length of each recording segment |

## Desktop recording

When `SYMPHONY_DESKTOP_RECORD` is enabled the entrypoint runs an `ffmpeg`
`x11grab` capture of the virtual display, writing timestamped MP4 **segments**
(`desktop-<YYYYMMDD>-<HHMMSS>.mp4`) into `SYMPHONY_RECORDINGS_DIR`. The default
directory is inside the bind-mounted workspace, so finished segments persist on
the host and survive container removal. Segmented output keeps already-written
chunks playable even when the container is force-killed during cleanup.

Symphony sets these variables automatically from the `container.record*`
settings in `WORKFLOW.md` (see `docs/containers.md`); you normally do not set
them by hand.
