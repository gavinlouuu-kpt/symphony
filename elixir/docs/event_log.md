# Run Event Log & Transcripts

Symphony records a per-issue, append-only log of meaningful Codex lifecycle
events so operators can review what an agent actually did — during a run and
after it finishes. This is the first step toward a Cursor-style agent dashboard:
a durable, scrollable record rather than a single live status line.

## What gets recorded

Every Codex app-server update the orchestrator integrates is offered to
`SymphonyElixir.EventLog`. High-frequency noise is dropped so the transcript
stays readable:

- **Kept:** turns, item lifecycle, command execution begin/end, file changes,
  plan updates, approvals, input requests, agent messages, errors.
- **Dropped:** streaming `*delta` events and token-count/usage chatter
  (any event whose name contains `delta` or `token`).

Each entry stores a monotonic `seq`, capture time (`at`), the raw `event` name,
a humanized `message`, and the `session_id`.

## Storage

`EventLog` is a supervised `GenServer` that keeps two views of the same data:

- **In-memory** (ETS), bounded to the most recent `memory_limit` events per
  issue (default `1000`) for fast transcript rendering.
- **Durable** newline-delimited JSON at `<event_log_dir>/<issue>.jsonl`, which
  keeps the full history and is rehydrated on demand after a restart.

Configure the directory with the `:event_log_dir` application env (defaults to
`log/events` under the working directory, alongside `log/symphony.log`).

## Surfaces

- **Dashboard:** each running session row has a **Transcript** button that opens
  a modal listing recent activity (newest first).
- **JSON API:**
  - `GET /api/v1/:issue_identifier/events` — full transcript, oldest first.
  - `GET /api/v1/:issue_identifier` — now includes a populated `recent_events`
    array (previously only the single latest event).

## Not yet covered (follow-ups)

- File rotation/retention for `*.jsonl` (history grows unbounded on disk today).
- Structured step/tool-call spans and per-run cost (the natural OpenTelemetry
  seam once events flow through this single capture point).
- Interactive control (responding to blocked agents from the dashboard).
