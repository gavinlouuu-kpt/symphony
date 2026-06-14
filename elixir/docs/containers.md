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
  features: ["auto"]                     # reusable features to install; "auto" detects from the repo
  keep_pr_desktops: true                 # keep a finished issue's desktop alive until its PR is merged/closed
  record: false                          # record the virtual desktop with ffmpeg for demo/review
  recordings_dir: .symphony/recordings   # where recordings land (relative to the workspace mount)
  record_framerate: 10                   # recording frame rate (fps)
  record_segment_seconds: 60             # length of each recording segment
  extra_run_args:                        # appended verbatim to `docker run`
    - "--volume"
    - "/home/you/.codex/auth.json:/root/.codex/auth.json:ro"
```

Build the default desktop image with:

```bash
docker build -t symphony-agent-desktop:latest elixir/docker/agent-desktop
```

## Container orchestrator: setup, debug, review

`SymphonyElixir.ContainerOrchestrator` wraps the desktop lifecycle in three
phases so the base image can stay small and desktops can outlive a single run:

- **setup** — when a container starts, the orchestrator inspects the issue's
  bind-mounted workspace, decides which reusable *features* the repo needs, and
  installs them into the container.
- **debug** — `ContainerOrchestrator.diagnostics/1` returns a snapshot (engine
  status, installed feature markers, recent desktop logs) for troubleshooting an
  agent that misbehaves inside its desktop.
- **review** — finished issues whose pull request is still open keep their
  desktop alive; the orchestrator reaps it once the PR is merged or closed.

## Reusable features (setup)

Instead of baking every toolchain into `symphony-agent-desktop`, Symphony
detects what a repository needs and installs it on first use. Features are
defined once in `SymphonyElixir.ContainerFeatures` and reused across every
issue. The built-in catalog:

| Feature   | Detected from                                              | Installs                              |
|-----------|------------------------------------------------------------|---------------------------------------|
| `make`    | `Makefile` / `GNUmakefile`                                 | `build-essential`, `make`             |
| `docker`  | `Dockerfile`, `docker-compose.yml`, `.devcontainer/`       | `docker.io` (Docker CLI)              |
| `node`    | `package.json`                                             | `corepack enable`                     |
| `python`  | `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile`| `python3`, `python3-pip`, venv        |
| `rust`    | `Cargo.toml`                                               | `rustc`, `cargo`                      |
| `go`      | `go.mod`                                                   | `golang-go`                           |
| `browser` | Playwright/Puppeteer/Cypress config or dependency          | `playwright install --with-deps chromium` |

Configure via `container.features`:

- `["auto"]` (default) — auto-detect from the workspace.
- An explicit list (e.g. `["make", "browser"]`) — install exactly those.
- Combine `"auto"` with explicit ids to force extras on top of detection.
- `[]` — disable provisioning entirely.

Provisioning is **idempotent and reusable**: each feature first runs a fast
"already installed?" check (the base image already ships Node and `git`) and
drops a marker under `/var/lib/symphony/features/<id>`, so reusing a container
across turns and retries re-runs each recipe as a cheap no-op. Failures are
logged and never abort the agent run.

The `docker` feature installs only the Docker CLI; running Docker *inside* the
container (docker-in-docker) additionally needs `--privileged` (or a mounted
host socket) via `extra_run_args`.

## Keeping PR desktops alive (review)

By default (`container.keep_pr_desktops: true`) a desktop is **not** torn down
the moment its issue reaches a terminal state. If the issue still has an open
pull request, Symphony keeps the container and its workspace alive so reviewers
can drive the desktop while the PR is in flight. On each poll the orchestrator
re-checks every retained desktop and reaps it (container + workspace) once the
PR is merged or closed ("outdated").

PR status is resolved with the GitHub CLI (`gh pr view`) inside the workspace,
so `gh` must be available and authenticated on the orchestrator host for
retention to engage; when it cannot determine an open PR, the desktop is cleaned
up as before. Set `keep_pr_desktops: false` to always tear desktops down at
terminal state. Retention applies to desktops on the orchestrator host only;
issues dispatched to `worker.ssh_hosts` keep the existing cleanup path.

## Recording desktops for demo and review

Set `container.record: true` to capture each agent's virtual desktop to video so
runs can be replayed later for demos and PR review. When enabled, Symphony passes
`SYMPHONY_DESKTOP_RECORD=1` (plus the recording directory, frame rate, and segment
length) into the container, and the desktop entrypoint runs an `ffmpeg` `x11grab`
capture of the display.

- **Where recordings go.** By default recordings are written under the issue
  workspace at `container.recordings_dir` (default `.symphony/recordings`).
  Because the workspace is bind-mounted from the host, finished segments persist
  on the host and outlive the container. An absolute `recordings_dir` keeps the
  recording inside the container only (no host copy), so the dashboard cannot
  serve it back.
- **Segmented files.** Recordings are split into timestamped MP4 segments
  (`desktop-<timestamp>.mp4`, `record_segment_seconds` long). Segmenting keeps
  already-written chunks playable even when a container is force-removed at
  cleanup, which would otherwise truncate a single growing file.
- **Reviewing recordings.** Recordings for a running or blocked issue are listed
  on its dashboard desktop card with direct playback links, and a red `● REC`
  badge marks desktops that are actively recording. They are also available over
  the JSON API:

  ```text
  GET /api/v1/<issue_identifier>/recordings            # list recordings (JSON)
  GET /api/v1/<issue_identifier>/recordings/<filename> # stream one recording
  ```

  The streaming route resolves filenames safely within the issue's recordings
  directory and refuses path traversal or symlinks that escape it.
- **Lifecycle.** Recordings live with the workspace, so they share its retention
  (see "Keeping PR desktops alive") and are removed when the workspace is reaped.
- **Requirements.** The desktop image must include `ffmpeg`
  (`symphony-agent-desktop` does). Recording adds CPU and disk overhead roughly
  proportional to the frame rate and screen geometry.

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
