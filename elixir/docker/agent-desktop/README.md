# Symphony Agent Desktop Image

Container image for Symphony's per-issue agent containers. Each running issue
gets one container built from this image, with:

- The Codex CLI (`codex app-server` is spawned inside the container via
  `docker exec` by the orchestrator).
- A virtual desktop (Xvfb + openbox + xterm) where GUI tools launched by the
  agent appear, plus an interactive terminal opened in the issue workspace.
- A noVNC endpoint on container port `6080` so the Symphony web dashboard can
  embed a fully interactive view of the desktop.

## Build

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Enable in WORKFLOW.md

```yaml
container:
  enabled: true
  image: symphony-agent-desktop:latest
  # Codex inside the container needs credentials. Mount them read-only:
  extra_run_args:
    - "--volume"
    - "/home/you/.codex/auth.json:/root/.codex/auth.json:ro"
```

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
