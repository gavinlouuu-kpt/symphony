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
    - "--volume"
    - "/path/to/codex-container-config.toml:/root/.codex/config.toml:ro"
codex:
  read_timeout_ms: 30000                 # allow app-server startup work to finish
```

Build the default desktop image with:

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Codex config for containers

Mount `auth.json` into the container so Codex can authenticate, but prefer a
container-specific `config.toml` instead of the operator's full desktop
`~/.codex/config.toml`. Desktop configs often enable plugins, MCP servers,
hooks, or workspace paths that are useful interactively but unnecessary for
unattended issue agents. Those startup checks run inside the container and can
make Symphony report `:response_timeout` before an app-server session opens.

A minimal container config usually looks like this:

```toml
model = "gpt-5.4-mini"
model_reasoning_effort = "medium"
plan_mode_reasoning_effort = "medium"

[features]
plugins = false

[projects."/workspace"]
trust_level = "trusted"
```

Disabling the `plugins` feature prevents Codex from doing plugin marketplace
discovery in the container. Trusting `/workspace` prevents interactive trust
prompts for the mounted issue checkout. The default desktop image also creates
`/root/.codex` and configures Git with:

```bash
git config --system --add safe.directory /workspace
```

That Git setting is needed because issue workspaces are bind-mounted from the
host and are commonly owned by the host user, while Codex runs as root inside
the default container image. Without it, Git may reject the repository with a
"dubious ownership" error.

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

## VPN egress for container traffic

Publishing noVNC on Tailscale controls how operators reach the desktop. It does
not automatically force the container's outbound internet traffic through a
host VPN. Docker bridge traffic follows the host routing and policy-routing
rules that match the bridge subnet.

If your Codex auth, package installs, or GitHub access depend on a host VPN,
verify from inside the running agent container, not only from the host:

```bash
docker exec symphony-agent-<ISSUE> bash -lc \
  'codex login status && node -e "fetch(\"https://chatgpt.com/cdn-cgi/trace\").then(r=>r.text()).then(console.log)"'
```

For a Tailscale full-tunnel setup, one common host-level pattern is to add an
`ip rule` for Docker's bridge subnet that looks up Tailscale's routing table,
then confirm the route from the Docker bridge perspective:

```bash
ip rule add pref 5190 from 172.17.0.0/16 lookup 52
ip route get 1.1.1.1 from 172.17.0.2 iif docker0
```

Persist that rule with your host's network manager or a systemd oneshot unit.
The exact table and subnet may differ across hosts, especially if you use
custom Docker networks or a VPN other than Tailscale.

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
- **Startup `:response_timeout` before a session appears**: Codex app-server
  did not answer Symphony's startup request in time. Check for plugin
  marketplace or MCP startup work inside the container with
  `docker exec symphony-agent-<ISSUE> ps -eo pid,ppid,stat,etime,cmd`. Prefer a
  minimal container config with `[features] plugins = false`, and raise
  `codex.read_timeout_ms` if the app-server legitimately needs longer to
  initialize.
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
- **Git reports dubious ownership for `/workspace`**: rebuild the default
  desktop image or add `git config --system --add safe.directory /workspace`
  to your custom image. This is expected when the workspace is owned by the
  host user but Git runs as root inside the container.
- **Git status shows every tracked file as deleted and untracked**: the
  workspace checkout is damaged, often because `.git/index` is missing or was
  truncated. Stop the issue agent and repair the checkout on the host with
  `git reset --mixed HEAD` followed by `git restore --worktree .`, or move the
  workspace aside and let Symphony recreate it.
- **`codex: command not found`**: the configured `container.image` does not
  include the Codex CLI. Rebuild from `docker/agent-desktop`, which installs
  `@openai/codex` globally.

## Notes and caveats

- Container mode applies to agents running on the orchestrator host. Issues
  dispatched to `worker.ssh_hosts` keep the existing SSH execution path.
- Codex inside the container needs credentials; mount `auth.json` (or pass an
  API key env var) via `extra_run_args`.
- Use a container-specific Codex config. Mounting a full desktop config can
  import plugin, MCP, hook, and workspace settings that do not belong in an
  unattended container.
- The noVNC endpoint is unauthenticated. Keep `novnc_host` on `127.0.0.1`
  unless you front it with an authenticating proxy; anyone who can reach the
  port (or the dashboard embedding it) can drive the agent's desktop.
- The Codex turn sandbox policy is rooted at the in-container workspace mount,
  mirroring the remote-worker behavior.
- The dashboard "Agent desktops" section only appears when at least one
  running or blocked session reports container info.
