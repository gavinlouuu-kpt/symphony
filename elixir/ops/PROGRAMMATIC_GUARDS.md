# Programmatic Guardrails

Symphony project behavior should not depend on prompt wording for state that the
orchestrator can verify itself. Use this split when adding or reviewing project
workflow rules.

## Enforce In Code Or Config

These are service invariants. They should be represented as typed config, hooks,
tracker state, or orchestrator checks before an LLM role agent starts work.

| Area | Programmatic owner | Reason |
|---|---|---|
| Project eligibility | Tracker required labels, active states, terminal states | Prevents accidental pickup and repeat work. |
| Repo sandbox readiness | `sandbox_contract` schema and workspace smoke check | Catches missing CMake, Qt/PySide, Python packages, `gh`, or repo bootstrap drift before implementation. |
| Workspace lifecycle | `after_create`, `before_run`, `after_run`, `before_remove` hooks | Keeps clone, bootstrap, validation setup, and cleanup deterministic. |
| Role-agent sequencing | `agent.role_agents` | Guarantees separate Planner, Generator, and Evaluator sessions instead of a single prompt pretending to be all roles. |
| Concurrency and retries | `max_concurrent_agents`, state limits, retry/backoff | Prevents retry storms and hidden parallel duplicate work. |
| Discord/OpenClaw routing | Profile route table, parent-thread resolution, intake labels | Keeps channel-to-project mapping deterministic. |
| Auth-sensitive writes | Approval policy plus `gh`/CLI-only unattended write paths | Avoids approval-gated connector stalls in autonomous workers. |
| PR/check readiness | Orchestrator or tracker gate over PR state and check runs | Prevents "looks done" handoff when required checks or review state are still unresolved. |
| Workpad shape | Structured tracker comment or stored phase record | Makes Planner/Generator/Evaluator evidence machine-checkable. |

## Leave As Instructions

These require judgment and can remain in the role-agent prompt, backed by the
programmatic guardrails above.

| Area | Instruction owner | Reason |
|---|---|---|
| Technical investigation | Planner/Generator/Evaluator | Requires repo understanding and issue-specific reasoning. |
| Design tradeoffs | Role agent | Depends on affected code and product constraints. |
| Risk-based validation choice | Role agent | Tests vary by changed surface and acceptance criteria. |
| Human-readable summaries | Role agent | Needs synthesis for issue comments, PRs, and Discord. |
| Ambiguous requirements | Role agent plus human handoff | Requires clarifying questions or documented assumptions. |

## Migration Rule

When a workflow instruction repeatedly appears in project prompts, logs, or
incident fixes, ask whether it can be converted to one of:

1. A typed workflow config section.
2. A workspace lifecycle hook.
3. A tracker/OpenClaw state transition.
4. A pre-dispatch or pre-handoff gate.
5. A reusable CLI/doctor check.

If yes, implement that first and keep only a short prompt note explaining the
observable contract to the role agent.
