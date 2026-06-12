# Per-issue agent containers and virtual desktops

When `container.enabled` is set, Symphony runs each issue's Codex agent inside
its own Docker (or Podman) container instead of directly on the orchestrator
host. Every container boots a virtual desktop (Xvfb + openbox + xterm) served
over noVNC, and the web dashboard embeds one interactive desktop frame per
running issue — so operators can watch an agent work, click into its terminal,
and poke around the workspace, similar to watching a Cursor IDE session.

## How it works

1. The orchestrator creates the per-issue workspace on the host as usual
   (including `after_create` hooks such as `git clone`).
2. `SymphonyElixir.ContainerRuntime` starts a container named
   `<name_prefix><issue_identifier>` from `container.image`, bind-mounting the
   workspace at `container.workspace_mount` (default `/workspace`) and
   publishing the in-container noVNC port (default `6080`) to an ephemeral
   host port bound to `container.novnc_host` (default `127.0.0.1`).
3. The Codex app-server is spawned *inside* the container via
   `docker exec -i <name> bash -lc 'cd /workspace && exec <codex.command>'`,
   so every shell command and GUI tool the agent launches runs in the
   container. GUI programs appear on the virtual desktop (`DISPLAY=:1`).
4. The container's noVNC URL is reported to the orchestrator alongside the
   worker runtime info, exposed through `/api/v1/state` and
   `/api/v1/<issue_identifier>` under `container`, and rendered in the
   dashboard's "Agent desktops" section.
5. When the issue's workspace is cleaned up (terminal state, removal, or
   re-dispatch cleanup), the container is force-removed as well. A container
   is reused across turns and retries while its issue stays active.

## Configuration

```yaml
container:
  enabled: true                          # default: false
  engine: docker                         # docker | podman
  image: symphony-agent-desktop:latest   # build from elixir/docker/agent-desktop
  name_prefix: symphony-agent-           # container name = prefix + issue identifier
  workspace_mount: /workspace            # where the issue workspace is mounted
  novnc_container_port: 6080             # noVNC port inside the container
  novnc_host: 127.0.0.1                  # host interface the noVNC port binds to
  extra_run_args:                        # appended verbatim to `docker run`
    - "--volume"
    - "/home/you/.codex/auth.json:/root/.codex/auth.json:ro"
```

Build the default desktop image with:

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Notes and caveats

- Container mode applies to agents running on the orchestrator host. Issues
  dispatched to `worker.ssh_hosts` keep the existing SSH execution path.
- Codex inside the container needs credentials; mount `auth.json` (or pass an
  API key env var) via `extra_run_args`.
- The noVNC endpoint is unauthenticated. Keep `novnc_host` on `127.0.0.1`
  unless you front it with an authenticating proxy; anyone who can reach the
  port (or the dashboard embedding it) can drive the agent's desktop.
- The Codex turn sandbox policy is rooted at the in-container workspace mount,
  mirroring the remote-worker behavior.
- The dashboard "Agent desktops" section only appears when at least one
  running or blocked session reports container info.
