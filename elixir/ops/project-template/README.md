# Symphony CUA Project Template

This directory is a reusable deployment template for running one Symphony instance per project.
For the guardrail ownership model, see `../PROGRAMMATIC_GUARDS.md`.

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

Linear is the default tracker. To use GitHub Issues instead, configure the tracker as:

```bash
SYMPHONY_TRACKER_KIND=github
GITHUB_TOKEN=...
SYMPHONY_TRACKER_PROJECT=gavinlouuu-kpt/template-agent-harness
SYMPHONY_TRACKER_REQUIRED_LABELS='["symphony"]'
SYMPHONY_TRACKER_ACTIVE_STATES='["open"]'
SYMPHONY_TRACKER_TERMINAL_STATES='["closed"]'
SYMPHONY_SOURCE_REPO_URL=https://github.com/gavinlouuu-kpt/symphony.git
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

## Sandbox Requirements Audit

Every project instance must define its sandbox contract before it is allowed to
run. During setup, review the repository's `AGENTS.md`, README, build docs, CI
workflows, package manifests, GUI/runtime docs, and test docs. Convert that
review into explicit `symphony.env` settings:

```bash
SYMPHONY_SANDBOX_CONTRACT_ENFORCED=true
SYMPHONY_SANDBOX_REQUIREMENTS_AUDITED=true
SYMPHONY_SANDBOX_REQUIRED_COMMANDS='["git","python3","cmake"]'
SYMPHONY_SANDBOX_REQUIRED_PYTHON_MODULES='["PySide6","h5py","cv2"]'
SYMPHONY_SANDBOX_REQUIRED_SYSTEM_PACKAGES='["qt6-base-dev","libopencv-dev"]'
SYMPHONY_AFTER_CREATE_EXTRA="python3 -m venv .symphony/venv && . .symphony/venv/bin/activate && pip install -r requirements-dev.txt"
SYMPHONY_SANDBOX_BOOTSTRAP_CHECK="command -v cmake >/dev/null && python3 -c 'import PySide6, h5py, cv2'"
SYMPHONY_SANDBOX_REQUIREMENTS_NOTES="GUI smoke uses noVNC; hardware-only checks need documented substitutes."
```

`bin/doctor.sh` and `bin/start.sh` fail until the audit is marked complete and
a bootstrap smoke check is declared. Symphony validates the typed
`sandbox_contract` at config load and runs its smoke check after cloning and
`SYMPHONY_AFTER_CREATE_EXTRA`, so an underbuilt sandbox is caught before the
issue agent starts planning or implementation.

Keep the audit conservative and repo-specific. If CI proves a command, package,
or smoke path is expected for normal local development, make it part of the
sandbox contract. Do not leave installable local dependencies such as `cmake`,
Qt/PySide, OpenCV, HDF5 bindings, or test runners as per-issue blockers.

## Evidence Requirements Audit

Every project instance must also define its evidence contract before it is
allowed to run. This is the minimum proof required before agents may mark a PR
ready, merge, close an issue, or remove the active routing label.

```bash
SYMPHONY_EVIDENCE_CONTRACT_ENFORCED=true
SYMPHONY_EVIDENCE_REQUIREMENTS_AUDITED=true
SYMPHONY_EVIDENCE_REQUIRED_CHECKS='["caller-network /predict succeeds","real product screenshot captured"]'
SYMPHONY_EVIDENCE_REQUIRED_ARTIFACTS='[".symphony/artifacts/label-studio-result.png"]'
SYMPHONY_EVIDENCE_REQUIRED_COMMANDS='["curl -fsS http://backend:9090/predict -d @payload.json"]'
SYMPHONY_EVIDENCE_REQUIREMENTS_NOTES="Health endpoints and parser tests do not prove runtime output."
```

Agents record required proof with the `symphony_record_evidence` dynamic tool,
which runs the command in the CUA workspace and writes `.symphony/evidence-ledger.jsonl`.
When the evidence contract is enforced, Symphony blocks handoff commands through
the sandbox tools until the ledger satisfies the configured checks, commands,
and artifact paths. The blocked commands include `gh pr ready`, `gh pr merge`,
`gh issue close`, and removal of the active routing label. `gh pr ready --undo`
is allowed so agents can move an invalid PR back to draft.

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

## Agent Harness

The project workflow is configured with `agent.role_agents`, so Symphony runs separate Planner,
Generator, and Evaluator Codex app-server sessions for each routed issue. The agents share the same
issue workspace and tracker workpad, but they do not share one chat context. Planner scopes the work,
Generator implements the accepted plan, and Evaluator independently reviews the result before handoff.

Within each role session, Codex subagents may be used for bounded independent work such as read-only
discovery, test/log analysis, validation triage, or focused review. Keep code edits, tracker labels,
PR handoff, and issue closure owned by the active role agent so the GitHub workpad remains the
auditable source of truth.

## OpenClaw Channel Bridge

Symphony can publish orchestrator lifecycle updates through OpenClaw, which then handles Discord or
any other configured OpenClaw channel. Symphony remains the scheduler/source of truth; OpenClaw is
the operator communication bridge.

Configure OpenClaw separately on the host:

```bash
openclaw onboard
openclaw channels add --channel discord
openclaw channels status --channel discord --probe
```

Then enable the bridge in `symphony.env`:

```bash
SYMPHONY_OPENCLAW_ENABLED=true
SYMPHONY_OPENCLAW_CHANNEL=discord
SYMPHONY_OPENCLAW_TARGET=channel:123456789012345678
```

The target format follows OpenClaw's `openclaw message send` CLI. For Discord, use
`channel:<id>` for a guild channel or `user:<id>` for a DM target. Symphony publishes dispatch,
role-agent completion, agent completion, blocked, and retry notifications. For Discord projects,
the canonical behavior is one thread per issue: dispatch creates or finds the thread, and later
role/status updates are posted in that thread.

### OpenClaw Issue Intake

The recommended shape is one pre-existing OpenClaw gateway per operator/trust boundary, with each
Symphony project instance represented as a profile in that gateway. OpenClaw owns Discord and routes
messages; each Symphony profile owns one GitHub-backed work queue.

The workflow is:

```text
Discord message -> OpenClaw message:received hook -> Symphony profile intake URL
  -> GitHub issue -> Symphony GitHub tracker poll -> implementation agent
```

Normal project discussion should stay in Discord until Gavin explicitly asks to
create or route the work. Configure the project-channel OpenClaw skill to answer
discussion with a short preliminary research pass, not a generic acknowledgement:
inspect the local reference checkout, `AGENTS.md`, relevant docs/files, and
existing issues/PRs when `gh` is available; then summarize likely affected
surfaces, risks, unknowns, and validation direction. Only the explicit intake
trigger should create the tracked Symphony/GitHub issue.

Enable intake on a GitHub-backed Symphony instance:

```bash
SYMPHONY_TRACKER_KIND=github
SYMPHONY_OPENCLAW_INTAKE_ENABLED=true
SYMPHONY_OPENCLAW_INTAKE_TOKEN="$(openssl rand -hex 32)"
SYMPHONY_OPENCLAW_INTAKE_URL=http://127.0.0.1:4401/api/v1/openclaw/issues
SYMPHONY_OPENCLAW_INTAKE_LABELS='["openclaw-intake"]'
```

For GitHub-backed OpenClaw intake, keep the bookkeeping label and active routing label separate.
`tracker.required_labels` should include the durable project label, commonly `symphony`, plus the
active routing label when that project should pick up only OpenClaw-created work. `openclaw-intake`
is the active routing label: remove it when a PR is ready for human review, the issue is blocked on
external input, or the issue is complete. Leave the issue open for normal review handoff; close it
only after the repository's merge/completion flow is done.

Install the reusable OpenClaw hook into the shared OpenClaw gateway:

```bash
mkdir -p ~/.openclaw/hooks
cp -R openclaw-hooks/symphony-issue-intake ~/.openclaw/hooks/
openclaw hooks enable symphony-issue-intake
```

Configure the OpenClaw gateway environment with a profile route table:

```json
{
  "default": "biowork",
  "channels": {
    "123456789012345678": "biowork",
    "234567890123456789": "mib-studio"
  },
  "profiles": {
    "biowork": {
      "url": "http://127.0.0.1:4401/api/v1/openclaw/issues",
      "tokenEnv": "SYMPHONY_OPENCLAW_INTAKE_TOKEN_BIOWORK",
      "channel": "discord",
      "target": "channel:123456789012345678",
      "labels": ["openclaw-intake"]
    },
    "mib-studio": {
      "url": "http://127.0.0.1:4402/api/v1/openclaw/issues",
      "tokenEnv": "SYMPHONY_OPENCLAW_INTAKE_TOKEN_MIB",
      "channel": "discord",
      "target": "channel:234567890123456789",
      "labels": ["openclaw-intake"]
    }
  }
}
```

Set `SYMPHONY_OPENCLAW_PROFILES=/path/to/profiles.json` in the OpenClaw gateway environment, along
with the referenced token env vars, then restart OpenClaw. In Discord, create work with:

```text
issue Add multi-prompt SAM2 annotation

Users should be able to provide several positive/negative prompts before backend inference runs.
```

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
