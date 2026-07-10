const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

const AUDIT_MARKER = "[symphony-role-audit-warning]";
const DEFAULT_PROFILES_PATH = "/home/gavin/.openclaw/symphony/profiles.json";
const STATE_PATH = "/home/gavin/.openclaw/symphony/mandatory-role-audit.json";
const LOG_PATH = "/home/gavin/.openclaw/logs/symphony-role-audit.jsonl";
const AGENTS_ROOT = "/home/gavin/.openclaw/agents";
const ROLE_AGENTS = ["symphony-planner", "symphony-generator", "symphony-evaluator"];
const EVALUATOR_AGENT = ["symphony-evaluator"];
const ROLE_EVIDENCE_GRACE_MS = 5 * 60 * 1000;
const DEFAULT_LOOKBACK_MS = 60 * 60 * 1000;
const DUPLICATE_SUPPRESS_MS = 10 * 60 * 1000;

const FINALIZATION_RE = /\b(?:created|opened|create|open|finali[sz]e|handoff|ready for review|complete|done|mark(?:ed)? complete|mark(?:ed)? done)\b/i;
const EVALUATION_RE = /\b(?:PASS|NEEDS-DISCUSSION|validation(?:s)?|validated|evaluator|tests? passed|posted evidence|ctest|cmake|check_docs|issue comment)\b/i;
const INTAKE_STATUS_RE = /^(?:Created GitHub issue\b|Symphony issue intake\b|\[symphony-role-audit-repair\])/i;

module.exports = async function handler(event) {
  if (event.type !== "message") {
    return;
  }

  if (event.action === "received") {
    recordInbound(event);
    return;
  }

  if (event.action === "sent") {
    await auditSent(event);
  }
};

function recordInbound(event) {
  const context = event.context || {};
  const channelId = resolveChannelId(context);
  const profile = resolveProfile(channelId);

  if (!profile) {
    return;
  }

  const now = Date.now();
  const state = loadState();
  state.sessions = state.sessions || {};
  state.channels = state.channels || {};

  const record = {
    at: now,
    profileName: profile.name,
    channelId,
    sessionKey: event.sessionKey || "",
    preview: preview(context.content)
  };

  if (event.sessionKey) {
    state.sessions[event.sessionKey] = record;
  }

  if (channelId) {
    state.channels[channelId] = record;
  }

  saveState(state);
}

async function auditSent(event) {
  const context = event.context || {};

  if (context.success === false) {
    return;
  }

  const content = String(context.content || "");

  if (!content.trim() || content.includes(AUDIT_MARKER) || INTAKE_STATUS_RE.test(content.trim())) {
    return;
  }

  const requiredRoles = rolesRequiredFor(content);

  if (requiredRoles.length === 0) {
    return;
  }

  const channelId = resolveChannelId(context);
  const profile = resolveProfile(channelId);

  if (!profile) {
    return;
  }

  const state = loadState();
  const sessionRecord = event.sessionKey ? state.sessions?.[event.sessionKey] : null;
  const channelRecord = channelId ? state.channels?.[channelId] : null;
  const since = Math.max(0, (sessionRecord?.at || channelRecord?.at || Date.now() - DEFAULT_LOOKBACK_MS) - ROLE_EVIDENCE_GRACE_MS);
  const missing = requiredRoles.filter((agentId) => !hasRecentRoleEvidence(agentId, since));

  if (missing.length === 0) {
    return;
  }

  const duplicateKey = [
    "sent",
    event.sessionKey || "",
    channelId || "",
    missing.join(","),
    content.slice(0, 160)
  ].join("|");

  if (isDuplicate(state, duplicateKey)) {
    return;
  }

  const violation = {
    ts: new Date().toISOString(),
    sessionKey: event.sessionKey || "",
    channelId,
    profileName: profile.name,
    requiredRoles,
    missing,
    since,
    preview: preview(content)
  };

  appendLog(violation);
  markDuplicate(state, duplicateKey);
  saveState(state);

  const repair = await maybeCreateBackfillIssue(profile, channelId, violation, content);

  if (repair && repair.ok && repair.message) {
    await sendReply(profile, channelId, buildRepair(profile.name, missing, repair.message));
    return;
  }

  await sendReply(profile, channelId, buildWarning(profile.name, missing, repair));
}

function rolesRequiredFor(content) {
  if (!EVALUATION_RE.test(content) && !FINALIZATION_RE.test(content)) {
    return [];
  }

  if (/\b(?:created|opened|finali[sz]e|handoff|ready for review|mark(?:ed)? complete|mark(?:ed)? done)\b/i.test(content)) {
    return ROLE_AGENTS;
  }

  return EVALUATOR_AGENT;
}

function hasRecentRoleEvidence(agentId, sinceMs) {
  const sessionsDir = path.join(AGENTS_ROOT, agentId, "sessions");

  try {
    const entries = fs.readdirSync(sessionsDir, { withFileTypes: true });

    for (const entry of entries) {
      const filePath = path.join(sessionsDir, entry.name);

      if (entry.isDirectory()) {
        if (directoryHasRecentFile(filePath, sinceMs)) {
          return true;
        }
        continue;
      }

      if (!entry.isFile()) {
        continue;
      }

      if (!isSessionEvidenceFile(entry.name)) {
        continue;
      }

      if (fs.statSync(filePath).mtimeMs >= sinceMs) {
        return true;
      }
    }
  } catch (_error) {
    return false;
  }

  return false;
}

function directoryHasRecentFile(dir, sinceMs) {
  let entries;

  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_error) {
    return false;
  }

  for (const entry of entries) {
    const filePath = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      if (directoryHasRecentFile(filePath, sinceMs)) {
        return true;
      }
      continue;
    }

    if (entry.isFile() && isSessionEvidenceFile(entry.name) && fs.statSync(filePath).mtimeMs >= sinceMs) {
      return true;
    }
  }

  return false;
}

function isSessionEvidenceFile(name) {
  return name.endsWith(".jsonl") || name.endsWith(".json") || name === "sessions.json";
}

function resolveProfile(channelId) {
  if (!channelId) {
    return null;
  }

  const config = loadProfilesConfig();
  const profileName = config?.channels?.[channelId] || config?.default;
  const profile = profileName && config?.profiles ? config.profiles[profileName] : null;

  if (!profile) {
    return null;
  }

  return {
    name: profileName,
    channel: profile.channel || process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    account: profile.account || process.env.SYMPHONY_OPENCLAW_ACCOUNT,
    target: profile.target || `channel:${channelId}`,
    url: profile.url || "",
    token: profile.token || (profile.tokenEnv ? process.env[profile.tokenEnv] : ""),
    labels: Array.isArray(profile.labels) ? profile.labels : []
  };
}

function resolveChannelId(context) {
  const candidates = [
    context.channelId,
    context.groupId,
    context.conversationId,
    context.to,
    context.target
  ];

  for (const candidate of candidates) {
    const value = String(candidate || "").trim();

    if (!value) {
      continue;
    }

    const channelMatch = value.match(/^channel:(\d+)$/);
    if (channelMatch) {
      return channelMatch[1];
    }

    if (/^\d{12,25}$/.test(value)) {
      return value;
    }
  }

  return "";
}

function loadProfilesConfig() {
  const source = process.env.SYMPHONY_OPENCLAW_PROFILES || DEFAULT_PROFILES_PATH;

  try {
    if (source.trim().startsWith("{")) {
      return JSON.parse(source);
    }

    return JSON.parse(fs.readFileSync(source, "utf8"));
  } catch (error) {
    console.error(`[symphony-role-agent-audit] failed to read profiles config: ${error.message}`);
    return null;
  }
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  } catch (_error) {
    return {};
  }
}

function saveState(state) {
  fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
  fs.writeFileSync(`${STATE_PATH}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  fs.renameSync(`${STATE_PATH}.tmp`, STATE_PATH);
}

function appendLog(entry) {
  fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true });
  fs.appendFileSync(LOG_PATH, `${JSON.stringify(entry)}\n`);
}

function isDuplicate(state, key) {
  const now = Date.now();
  const duplicates = state.duplicates || {};
  const last = duplicates[key] || 0;
  return now - last < DUPLICATE_SUPPRESS_MS;
}

function markDuplicate(state, key) {
  const now = Date.now();
  state.duplicates = state.duplicates || {};
  state.duplicates[key] = now;

  for (const [entryKey, seenAt] of Object.entries(state.duplicates)) {
    if (now - seenAt > DUPLICATE_SUPPRESS_MS) {
      delete state.duplicates[entryKey];
    }
  }
}

function preview(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 240);
}

async function maybeCreateBackfillIssue(profile, channelId, violation, content) {
  if (!profile.url || !profile.token || !requiresFullRoleBackfill(violation.requiredRoles)) {
    return null;
  }

  try {
    const response = await fetch(profile.url, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${profile.token}`,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        title: backfillTitle(profile.name, content),
        body: backfillBody(profile.name, violation, content),
        labels: profile.labels || [],
        source: {
          channel: profile.channel || "discord",
          channel_id: channelId || "",
          sender: "symphony-role-agent-audit",
          session_key: violation.sessionKey || ""
        }
      })
    });
    const payload = await readJson(response);

    if (response.ok && payload && payload.message) {
      return { ok: true, message: payload.message };
    }

    const message = payload && payload.error && payload.error.message
      ? payload.error.message
      : `HTTP ${response.status}`;

    return { ok: false, message };
  } catch (error) {
    return { ok: false, message: error.message || String(error) };
  }
}

function requiresFullRoleBackfill(requiredRoles) {
  return ROLE_AGENTS.every((agentId) => requiredRoles.includes(agentId));
}

function backfillTitle(profileName, content) {
  if (/\bLocate\s+Anything\b/i.test(content)) {
    return "Backfill Symphony workflow for Locate Anything feature";
  }

  return `Backfill Symphony workflow for ${profileName} Discord completion`;
}

function backfillBody(profileName, violation, content) {
  return [
    `OpenClaw posted a finalization message in the \`${profileName}\` Discord workflow without mandatory role-agent evidence.`,
    "",
    "This issue backfills that work into the tracked Symphony/GitHub workflow so Planner -> Generator -> Evaluator can repair or validate it with durable evidence.",
    "",
    `Missing role agents: ${violation.missing.map((item) => `\`${item}\``).join(", ")}`,
    `Original session key: \`${violation.sessionKey || "unknown"}\``,
    "",
    "Original finalization message:",
    "",
    "```text",
    content.trim().slice(0, 6000),
    "```",
    "",
    "Repair instructions:",
    "- Treat any direct local implementation as untrusted WIP until the role-agent workflow validates it.",
    "- Planner must restate scope, acceptance criteria, risk, and validation.",
    "- Generator must implement or reconcile the work only from the accepted plan.",
    "- Evaluator must independently verify the result before the issue is marked ready or complete.",
    "- Use bounded autonomy for routine blockers and ask Gavin only for hard blockers."
  ].join("\n");
}

async function readJson(response) {
  try {
    return await response.json();
  } catch (_error) {
    return null;
  }
}

function buildWarning(profileName, missing, repair) {
  const repairNote = repair && repair.ok === false
    ? ` Auto-backfill failed: ${repair.message}.`
    : "";

  return `${AUDIT_MARKER} Mandatory Symphony role-agent gate failed for profile \`${profileName}\`. Missing recent isolated session evidence: ${missing.map((item) => `\`${item}\``).join(", ")}. Treat the previous PASS/finalization/evaluation as invalid until OpenClaw reruns the work through the required role agent(s).${repairNote}`;
}

function buildRepair(profileName, missing, message) {
  return `[symphony-role-audit-repair] Mandatory Symphony role-agent gate failed for profile \`${profileName}\`. Missing recent isolated session evidence: ${missing.map((item) => `\`${item}\``).join(", ")}. I created a tracked backfill issue so Symphony can rerun the work through Planner -> Generator -> Evaluator.\n${message}`;
}

async function sendReply(profile, channelId, message) {
  const command = splitCommand(process.env.SYMPHONY_OPENCLAW_COMMAND || "openclaw");
  const executable = command[0];
  const baseArgs = command.slice(1);
  const args = baseArgs.concat(["message", "send", "--channel", profile.channel || "discord"]);

  if (profile.account) {
    args.push("--account", profile.account);
  }

  args.push("--target", profile.target || `channel:${channelId}`);
  args.push("--message", message);

  await execFile(executable, args);
}

function splitCommand(command) {
  const parts = String(command || "openclaw").match(/(?:[^\s"]+|"[^"]*")+/g) || ["openclaw"];
  return parts.map((part) => part.replace(/^"|"$/g, ""));
}

function execFile(executable, args) {
  return new Promise((resolve) => {
    const child = spawn(executable, args, { stdio: "ignore" });
    child.on("error", (error) => {
      console.error(`[symphony-role-agent-audit] failed to send reply: ${error.message}`);
      resolve();
    });
    child.on("close", () => resolve());
  });
}
