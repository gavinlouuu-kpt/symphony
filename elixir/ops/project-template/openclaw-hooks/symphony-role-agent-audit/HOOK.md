---
name: symphony-role-agent-audit
description: "Warn and backfill when Symphony Discord evaluations or finalization messages lack recent mandatory role-agent evidence."
metadata:
  openclaw:
    events: ["message:received", "message:sent"]
    always: true
---

# Symphony Role Agent Audit

Tracks Symphony Discord channel activity and emits an operator-visible warning
when a finalization, PASS, validation, or handoff message is sent without recent
isolated role-agent session evidence.

For full Planner -> Generator -> Evaluator bypasses, the hook attempts a bounded
repair by creating a tracked Symphony/GitHub backfill issue using the configured
profile intake URL. Symphony then reruns the work through the required role
agents with durable issue/workpad evidence.

This is an audit hook, not a tool-call blocker. OpenClaw hook errors are logged
and do not cancel the original message, so the hook makes bypasses visible and
marks the prior result invalid until the mandatory role agents run.
