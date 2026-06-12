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
  # Codex inside the container needs credentials and a container-specific config.
  extra_run_args:
    - "--volume"
    - "/home/you/.codex/auth.json:/root/.codex/auth.json:ro"
    - "--volume"
    - "/path/to/codex-container-config.toml:/root/.codex/config.toml:ro"
codex:
  read_timeout_ms: 30000
```

The orchestrator bind-mounts each issue workspace at `/workspace` inside the
container and publishes the noVNC port on an ephemeral host port (bound to
`127.0.0.1` by default). The dashboard's "Agent desktops" section picks the
URL up automatically.

Use a minimal container config instead of mounting your full desktop
`~/.codex/config.toml`. A desktop config often enables plugins or local MCP
servers that are not needed in unattended containers and can slow or block
`codex app-server` startup.

```toml
model = "gpt-5.4-mini"
model_reasoning_effort = "medium"
plan_mode_reasoning_effort = "medium"

[features]
plugins = false

[projects."/workspace"]
trust_level = "trusted"
```

The image creates `/root/.codex` and marks `/workspace` as a system-wide Git
safe directory. This avoids Codex failing Git commands when the bind-mounted
workspace is owned by the host user but Codex runs as root in the container.

## Security notes

- The noVNC endpoint is unauthenticated; it is only published on
  `container.novnc_host` (default `127.0.0.1`). If you change that to a
  routable address, put an authenticating proxy in front of it.
- Anyone with access to the dashboard can interact with the agent's desktop
  and workspace.
- Mount `auth.json` read-only where possible. If the container must use a
  writable Codex home for logs and state, keep that writable state separate
  from the host's long-lived desktop config.

## Environment overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `SYMPHONY_DISPLAY` | `:1` | X display number |
| `SYMPHONY_DESKTOP_GEOMETRY` | `1440x900x24` | Virtual screen geometry |
| `SYMPHONY_VNC_PORT` | `5900` | In-container VNC port |
| `SYMPHONY_NOVNC_PORT` | `6080` | In-container noVNC (websocket) port |
| `SYMPHONY_WORKSPACE_DIR` | `/workspace` | Directory the desktop terminal opens in |
