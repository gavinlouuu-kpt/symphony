---
name: symphony-issue-intake
description: "Route OpenClaw channel issue requests into Symphony GitHub issue intake."
metadata:
  openclaw:
    emoji: "🎼"
    events: ["message:received"]
    always: true
---

# Symphony Issue Intake

Listens for inbound channel messages that start with `issue`, `/issue`, `gh issue`,
`github issue`, or `open issue`, creates a GitHub issue through the configured Symphony
profile, and replies to the originating channel with the new issue URL.

Feature approval phrases are also issue intake triggers in project channels:
`create feature`, `make feature`, `new feature`, `feature request`,
`create ticket`, `make ticket`, `create task`, `make task`, `implement this`,
`build this`, and `do it`. Bare approvals such as `Create feature` include
recent channel context in the issue body so Symphony can continue with bounded
autonomy instead of requiring Gavin to restate the proposal.

Use one OpenClaw gateway with one hook, then route each Discord channel to a Symphony
profile using `SYMPHONY_OPENCLAW_PROFILES`.

Example `profiles.json`:

```json
{
  "default": "symphony",
  "channels": {
    "123456789012345678": "symphony",
    "234567890123456789": "biowork"
  },
  "profiles": {
    "symphony": {
      "url": "http://127.0.0.1:4403/api/v1/openclaw/issues",
      "tokenEnv": "SYMPHONY_OPENCLAW_INTAKE_TOKEN_SYMPHONY",
      "channel": "discord",
      "target": "channel:123456789012345678",
      "labels": ["symphony"]
    },
    "biowork": {
      "url": "http://127.0.0.1:4401/api/v1/openclaw/issues",
      "tokenEnv": "SYMPHONY_OPENCLAW_INTAKE_TOKEN_BIOWORK",
      "channel": "discord",
      "target": "channel:234567890123456789",
      "labels": ["symphony"]
    }
  }
}
```

Set `SYMPHONY_OPENCLAW_PROFILES=/path/to/profiles.json` in the OpenClaw gateway
environment and enable this hook.
