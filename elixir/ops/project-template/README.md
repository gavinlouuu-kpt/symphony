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
SYMPHONY_DASHBOARD_PORT=4401
SYMPHONY_CUA_NAME_PREFIX=symphony-biowork
```

Each project instance should have a unique:

- `SYMPHONY_INSTANCE_ID`
- `SYMPHONY_INSTANCE_ROOT`
- `SYMPHONY_DASHBOARD_PORT`
- `SYMPHONY_WORKSPACE_ROOT`
- `SYMPHONY_CUA_NAME_PREFIX`

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

## Dashboard

The dashboard listens on `SYMPHONY_DASHBOARD_HOST:SYMPHONY_DASHBOARD_PORT`.

Use a distinct port per project instance, for example:

```text
biowork        4401
mib-studio-qt 4402
symphony      4403
```
