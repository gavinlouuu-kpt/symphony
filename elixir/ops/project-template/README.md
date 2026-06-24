# Symphony CUA Project Template

This directory is a reusable deployment template for running one Symphony instance per project.

The intended runtime shape is:

```text
one project instance -> one Symphony orchestrator process
one Linear issue     -> one CUA sandbox container
Codex/OpenAI auth    -> host only
project work         -> CUA sandbox via sandbox tools
```

## Create an Instance

From the Symphony Elixir directory, use the generator:

```bash
cd /home/gavin/Developer/symphony/elixir
ops/create-project-instance.sh biowork
```

Or pick an instance id and copy the template manually:

```bash
INSTANCE=biowork
ROOT=/home/gavin/Service/symphony/$INSTANCE

mkdir -p "$ROOT"
cp -R /home/gavin/Developer/symphony/elixir/ops/project-template/. "$ROOT/"
cp "$ROOT/symphony.env.example" "$ROOT/symphony.env"
```

Edit `$ROOT/symphony.env` and set at least:

```bash
LINEAR_API_KEY=...
SYMPHONY_LINEAR_PROJECT_SLUG=...
SYMPHONY_SOURCE_REPO_URL=...
SYMPHONY_INSTANCE_ID=biowork
SYMPHONY_INSTANCE_ROOT=/home/gavin/Service/symphony/biowork
SYMPHONY_WORKSPACE_ROOT=/home/cua/workspaces
SYMPHONY_DASHBOARD_PORT=4401
SYMPHONY_CUA_HOST=127.0.0.1
SYMPHONY_CUA_NAME_PREFIX=symphony-biowork
```

Each project instance should have a unique:

- `SYMPHONY_INSTANCE_ID`
- `SYMPHONY_INSTANCE_ROOT`
- `SYMPHONY_DASHBOARD_PORT`
- `SYMPHONY_CUA_HOST` when noVNC/API links must be reachable from another machine
- `SYMPHONY_CUA_NAME_PREFIX`

Keep `SYMPHONY_WORKSPACE_ROOT` as a path writable inside the CUA container. The default
`/home/cua/workspaces` is correct for the reference image.

Run checks:

```bash
cd "$ROOT"
bin/doctor.sh
```

Render the runtime workflow without starting Symphony:

```bash
SYMPHONY_RENDER_ONLY=1 bin/start.sh
```

Start in the foreground:

```bash
bin/start.sh
```

## Run With systemd User Services

Install the user unit once:

```bash
mkdir -p ~/.config/systemd/user
cp /home/gavin/Developer/symphony/elixir/ops/project-template/systemd/user/symphony@.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

Then enable one project instance:

```bash
systemctl --user enable --now symphony@biowork
systemctl --user status symphony@biowork
journalctl --user -u symphony@biowork -f
```

The unit expects each instance at:

```text
/home/gavin/Service/symphony/<instance-id>
```

## Rendered Runtime Files

`bin/start.sh` renders:

```text
runtime/WORKFLOW.runtime.md
```

from:

```text
WORKFLOW.md.template
symphony.env
```

Do not edit `runtime/WORKFLOW.runtime.md` directly. Edit `WORKFLOW.md.template` or `symphony.env`,
then restart the instance.

## CUA Image

By default, `SYMPHONY_CUA_IMAGE_BUILD=auto` builds the reference CUA image only when the configured
image tag is missing:

```bash
bin/build-cua-image.sh
```

Set `SYMPHONY_CUA_IMAGE_BUILD=never` when using a prebuilt image from a registry.

## Private Repositories

Codex runs on the host, but project commands run inside the CUA sandbox. The default `after_create`
hook clones the project from inside the sandbox:

```sh
git clone --depth 1 --branch "$SYMPHONY_SOURCE_REPO_BRANCH" "$SYMPHONY_SOURCE_REPO_URL" .
```

For private repositories, provide sandbox-side Git access using one of these patterns:

- Use an HTTPS URL with a read-only token in a project-specific secret mechanism.
- Mount an SSH deploy key with `cua.volumes` and customize `WORKFLOW.md.template`.
- Replace the default `after_create` hook with a host-prepared archive/download flow.

Do not mount host Codex auth into CUA. The one-orchestrator model keeps OpenAI/Codex auth on the
host and uses sandbox tools to operate inside CUA.

## noVNC Visibility

The default sandbox shell tool is headless: `sandbox_exec` runs commands over SSH, so noVNC will not
show terminal activity for normal code edits, builds, or tests.

For demo steps, real-user validation, browser/app startup, or any task where the operator should see
activity in noVNC, the agent should use `sandbox_visible_exec`. It opens a terminal on the CUA desktop,
runs the command from the issue workspace, records a transcript under `.symphony/visible-exec/`, waits
for completion, and leaves the terminal open for review.

## Dashboard

The dashboard listens on `SYMPHONY_DASHBOARD_HOST:SYMPHONY_DASHBOARD_PORT`.

The dashboard also renders a CUA sandbox inventory for running, retrying, and blocked issues. Set
`SYMPHONY_CUA_HOST` to a reachable host such as the same Tailscale/LAN address used by the dashboard
when operators need to open noVNC/API links from another machine. The default `127.0.0.1` keeps CUA
ports local-only.

The template defaults `SYMPHONY_CUA_DELETE_ON_TERMINAL=true`, so CUA containers are preserved during
running, retrying, blocked, and non-terminal review states, then closed when the Linear issue reaches
a configured terminal state.

Each instance uses a project-local SSH keypair by default:

```text
ssh/id_ed25519
ssh/id_ed25519.pub
```

`bin/start.sh` creates it automatically when `SYMPHONY_CUA_SSH_KEYGEN=auto`. The public key is mounted
into CUA as the authorized key, and the private key is used by Symphony for SSH commands into the sandbox.

Use a distinct port per project instance, for example:

```text
biowork        4401
mib-studio-qt 4402
symphony      4403
```
