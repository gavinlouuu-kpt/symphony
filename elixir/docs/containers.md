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
  novnc_host: 127.0.0.1                  # host interface the noVNC port binds to ("tailscale" supported)
  novnc_advertise_host: null             # host used in dashboard URLs (defaults to novnc_host; "tailscale" supported)
  extra_run_args:                        # appended verbatim to `docker run`
    - "--volume"
    - "/home/you/.codex/auth.json:/root/.codex/auth.json:ro"
```

Build the default desktop image with:

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Remote access over Tailscale

If Symphony runs on a dev server you reach over Tailscale (e.g. Tailscale
SSH), `127.0.0.1` URLs only work on the server itself. Set the special value
`tailscale` to bind and advertise on your tailnet instead:

```yaml
server:
  port: 4321
  host: tailscale # dashboard listens on this node's Tailscale IPv4
container:
  enabled: true
  novnc_host: tailscale # desktops bind to the Tailscale interface only
```

With this config:

- The dashboard is served on `http://<tailscale-ip>:4321/` (open it with the
  server's MagicDNS name or 100.x address from any device on your tailnet).
- Each container's noVNC port is published on the Tailscale interface only —
  not on localhost, the LAN, or the public internet.
- Dashboard desktop URLs advertise the server's MagicDNS name when available
  (falling back to the Tailscale IPv4), so the embedded frames work from any
  tailnet device.

Symphony resolves the address with the `tailscale` CLI (`tailscale ip -4` and
`tailscale status --json`), so `tailscaled` must be running on the server. If
you want different bind and URL hosts (for example bind `0.0.0.0` behind a
reverse proxy but advertise a proxy hostname), set `novnc_advertise_host`
explicitly; it also accepts the `tailscale` shorthand.

Because the noVNC endpoints are unauthenticated, binding to the Tailscale
interface is the recommended way to do remote access: reachability is then
governed by your tailnet ACLs rather than being open to the network.

## Troubleshooting Codex errors inside containers

If agent runs fail shortly after start, check the Codex app-server output
first — Symphony logs non-JSON Codex stream lines at warning level, and you
can also run the command manually:

```bash
docker exec -it symphony-agent-<ISSUE> bash -lc 'cd /workspace && codex app-server'
```

Common causes:

- **Missing credentials** (`401`, "Not logged in", or an immediate exit):
  Codex inside the container has no auth. Mount your `auth.json` read-only via
  `container.extra_run_args` (see above), or pass an API key env var with
  `--env`.
- **Sandbox errors** ("sandbox error", Landlock/seccomp failures, or every
  shell command failing with "Operation not permitted"): Codex's own sandbox
  often cannot initialize under Docker's default seccomp profile. Since the
  per-issue container already provides the isolation boundary, the usual fix
  is to let Codex run unsandboxed *inside* the container:

  ```yaml
  codex:
    thread_sandbox: danger-full-access
    approval_policy: never
  ```

  Alternatively, keep the Codex sandbox and relax the container instead, e.g.
  `extra_run_args: ["--security-opt", "seccomp=unconfined"]` (weaker container
  hardening; prefer the option above).
- **Network failures during turns** (DNS errors, package installs failing):
  the default turn sandbox policy denies network access. Set
  `codex.turn_sandbox_policy` with `networkAccess: true` as shown in the
  repository `WORKFLOW.md`.
- **`codex: command not found`**: the configured `container.image` does not
  include the Codex CLI. Rebuild from `docker/agent-desktop`, which installs
  `@openai/codex` globally.

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
