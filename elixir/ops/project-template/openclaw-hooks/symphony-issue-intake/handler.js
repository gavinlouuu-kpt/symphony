const fs = require("node:fs");
const { spawn } = require("node:child_process");

const ISSUE_PREFIX = /^\s*(?:\/?issue|gh\s+issue|github\s+issue|open\s+issue)\b/i;
const FEATURE_INTAKE_PREFIX = /^\s*(?:create\s+feature|make\s+feature|new\s+feature|feature\s+request|create\s+ticket|make\s+ticket|create\s+task|make\s+task|implement\s+this|build\s+this|do\s+it)\b/i;
const FEATURE_STRIP_PREFIX = /^\s*(?:create\s+feature|make\s+feature|new\s+feature|feature\s+request|create\s+ticket|make\s+ticket|create\s+task|make\s+task|implement\s+this|build\s+this|do\s+it)\b[:\-\s]*/i;
const BARE_FEATURE_APPROVAL = /^\s*(?:create\s+feature|make\s+feature|new\s+feature|feature\s+request|create\s+ticket|make\s+ticket|create\s+task|make\s+task|implement\s+this|build\s+this|do\s+it)\s*[.!?]*\s*$/i;
const LEADING_DISCORD_MENTION = /^\s*<@!?\d+>\s*/;
const LEADING_BOT_NAME_MENTION = /^\s*@(?:Hands\s+of\s+Jovin|gavin-claw)\b[:,]?\s*/i;
const RECENT_CONTEXT_LIMIT = 12;
const MAX_RECENT_CONTEXT_CHARS = 6000;

module.exports = async function handler(event) {
  if (event.type !== "message" || event.action !== "received") {
    return;
  }

  const context = event.context || {};
  const text = issueCommandText(context.content);
  const trigger = intakeTrigger(text);

  if (!trigger) {
    return;
  }

  const profile = await resolveProfile(context);

  if (!profile || !profile.url || !profile.token) {
    await sendReply(profile, context, "Symphony issue intake is not configured for this channel.");
    return;
  }

  try {
    const issuePayload = await buildIssuePayload(trigger, text, profile, context);
    const response = await fetch(profile.url, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${profile.token}`,
        "content-type": "application/json"
      },
      body: JSON.stringify(issuePayload)
    });

    const payload = await readJson(response);

    if (response.ok && payload && payload.message) {
      await sendReply(profile, context, payload.message);
    } else {
      const message = payload && payload.error && payload.error.message
        ? payload.error.message
        : `HTTP ${response.status}`;

      await sendReply(profile, context, `Symphony issue intake failed: ${message}`);
    }
  } catch (error) {
    await sendReply(profile, context, `Symphony issue intake failed: ${error.message || error}`);
  }
};

function issueCommandText(content) {
  let text = String(content || "").trim();

  // Discord exposes content for mentioned messages even when message-content
  // intent is limited. In that case the command commonly starts after the bot
  // mention, so normalize it before matching `issue ...`.
  for (let index = 0; index < 3; index += 1) {
    const next = text
      .replace(LEADING_DISCORD_MENTION, "")
      .replace(LEADING_BOT_NAME_MENTION, "")
      .trim();

    if (next === text) {
      return text;
    }

    text = next;
  }

  return text;
}

function intakeTrigger(text) {
  if (ISSUE_PREFIX.test(text)) {
    return { kind: "issue" };
  }

  if (FEATURE_INTAKE_PREFIX.test(text)) {
    return { kind: "feature" };
  }

  return null;
}

async function buildIssuePayload(trigger, text, profile, context) {
  const source = {
    channel: profile.channel || process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    channel_id: context.channelId || "",
    message_id: messageId(context),
    sender: senderName(context)
  };

  const payload = {
    text,
    labels: profile.labels || [],
    source
  };

  if (trigger.kind !== "feature") {
    return payload;
  }

  const recent = BARE_FEATURE_APPROVAL.test(text)
    ? await readRecentMessages(profile, context)
    : [];
  const stripped = text.replace(FEATURE_STRIP_PREFIX, "").trim();
  const title = featureTitle(stripped, recent);
  const body = featureBody(text, stripped, recent);

  return {
    ...payload,
    title,
    body
  };
}

function featureTitle(stripped, recent) {
  const direct = firstNonEmptyLine(stripped);

  if (direct) {
    return normalizeTitle(direct);
  }

  const recentText = recent.map((message) => message.content || "").join("\n");

  if (/\bLocate\s+Anything\b/i.test(recentText)) {
    return "Add Locate Anything support to Biowork";
  }

  const candidate = recent
    .map((message) => firstUsefulLine(message.content || ""))
    .find(Boolean);

  if (candidate) {
    return normalizeTitle(candidate);
  }

  return "Create approved feature from Discord discussion";
}

function featureBody(originalText, stripped, recent) {
  const lines = [
    "Gavin approved feature creation from Discord.",
    "",
    `Approval message: ${originalText.trim()}`
  ];

  if (stripped) {
    lines.push("", "Requested scope:", stripped);
  }

  if (recent.length > 0) {
    lines.push("", "Recent Discord context:", recentContextBlock(recent));
  }

  lines.push(
    "",
    "Autonomy instructions:",
    "- Use bounded autonomy to unblock routine workflow gaps.",
    "- Choose conservative implementation assumptions and record them in the workpad.",
    "- Ask Gavin only for secrets, destructive operations, paid external resources, licensing/legal approval, unavailable required hardware/data, or product decisions where a wrong assumption would materially change the feature."
  );

  return lines.join("\n").trim();
}

async function readRecentMessages(profile, context) {
  const command = splitCommand(process.env.SYMPHONY_OPENCLAW_COMMAND || "openclaw");
  const executable = command[0];
  const baseArgs = command.slice(1);
  const args = baseArgs.concat([
    "message",
    "read",
    "--channel",
    profile.channel || process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    "--target",
    profile.target || defaultTarget(String(context.channelId || "")),
    "--limit",
    String(RECENT_CONTEXT_LIMIT),
    "--json"
  ]);

  if (profile.account) {
    args.splice(args.indexOf("--target"), 0, "--account", profile.account);
  }

  const output = await execFileCapture(executable, args);
  const payload = parseJsonFromOutput(output.stdout);
  const messages = payload?.payload?.messages;

  if (!Array.isArray(messages)) {
    return [];
  }

  const currentId = messageId(context);

  return messages
    .filter((message) => String(message.content || "").trim() !== "")
    .filter((message) => !currentId || String(message.id || "") !== currentId)
    .reverse();
}

function recentContextBlock(recent) {
  let total = 0;
  const lines = [];

  for (const message of recent) {
    const author = authorName(message);
    const timestamp = message.timestampUtc || message.timestamp || "";
    const content = String(message.content || "").replace(/\s+/g, " ").trim();
    const line = `- ${timestamp} ${author}: ${content}`;

    if (total + line.length > MAX_RECENT_CONTEXT_CHARS) {
      break;
    }

    total += line.length;
    lines.push(line);
  }

  return lines.join("\n");
}

function authorName(message) {
  const author = message.author || {};
  return author.global_name || author.username || author.id || "unknown";
}

function firstUsefulLine(content) {
  return String(content || "")
    .split("\n")
    .map((line) => line.replace(/\*\*/g, "").replace(/^[\s#*-]+/, "").trim())
    .find((line) => {
      if (!line) {
        return false;
      }

      if (/^(validated|created|what.?s in|next step|phase \d+:?)$/i.test(line)) {
        return false;
      }

      return line.length >= 12;
    }) || "";
}

function firstNonEmptyLine(text) {
  return String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean) || "";
}

function normalizeTitle(title) {
  return String(title || "")
    .replace(/\*\*/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 250) || "Create approved feature from Discord discussion";
}

function parseJsonFromOutput(output) {
  const text = String(output || "");
  const start = text.indexOf("{");

  if (start < 0) {
    return null;
  }

  try {
    return JSON.parse(text.slice(start));
  } catch (_error) {
    return null;
  }
}

async function resolveProfile(context) {
  const config = loadProfilesConfig();
  const channelId = String(context.channelId || "");

  if (config && config.profiles) {
    const directProfile = resolveConfiguredProfile(config, channelId);

    if (directProfile) {
      return normalizeProfile(directProfile, channelId);
    }

    for (const parentChannelId of explicitParentChannelIds(context)) {
      const parentProfile = resolveConfiguredProfile(config, parentChannelId);

      if (parentProfile) {
        return normalizeProfile(parentProfile, parentChannelId);
      }
    }

    const discoveredParentId = await discoverParentChannelId(context, channelId);
    const parentProfile = resolveConfiguredProfile(config, discoveredParentId);

    if (parentProfile) {
      return normalizeProfile(parentProfile, discoveredParentId);
    }

    return null;
  }

  return normalizeProfile({
    url: process.env.SYMPHONY_OPENCLAW_INTAKE_URL,
    token: process.env.SYMPHONY_OPENCLAW_INTAKE_TOKEN,
    channel: process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    account: process.env.SYMPHONY_OPENCLAW_ACCOUNT,
    target: process.env.SYMPHONY_OPENCLAW_TARGET,
    labels: parseJsonArray(process.env.SYMPHONY_OPENCLAW_INTAKE_LABELS)
  }, channelId);
}

function resolveConfiguredProfile(config, channelId) {
  const profileName =
    (channelId && config.channels && config.channels[channelId]) || config.default;

  return profileName ? config.profiles[profileName] : null;
}

function loadProfilesConfig() {
  const source = process.env.SYMPHONY_OPENCLAW_PROFILES;

  if (!source) {
    return null;
  }

  try {
    if (source.trim().startsWith("{")) {
      return JSON.parse(source);
    }

    return JSON.parse(fs.readFileSync(source, "utf8"));
  } catch (error) {
    console.error(`[symphony-issue-intake] failed to read profiles config: ${error.message}`);
    return null;
  }
}

function normalizeProfile(profile, channelId) {
  if (!profile) {
    return null;
  }

  const token = profile.token || (profile.tokenEnv ? process.env[profile.tokenEnv] : null);

  return {
    url: profile.url,
    token,
    channel: profile.channel || process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    account: profile.account || process.env.SYMPHONY_OPENCLAW_ACCOUNT,
    target: profile.target || process.env.SYMPHONY_OPENCLAW_TARGET || defaultTarget(channelId),
    labels: Array.isArray(profile.labels) ? profile.labels : []
  };
}

function explicitParentChannelIds(context) {
  const metadata = context.metadata || {};
  const channel = context.channel || metadata.channel || {};

  return uniq([
    context.parentChannelId,
    context.parent_channel_id,
    context.parentId,
    context.parent_id,
    metadata.parentChannelId,
    metadata.parent_channel_id,
    metadata.parentId,
    metadata.parent_id,
    channel.parentChannelId,
    channel.parent_channel_id,
    channel.parentId,
    channel.parent_id
  ]);
}

async function discoverParentChannelId(context, channelId) {
  if (!channelId) {
    return "";
  }

  const command = splitCommand(process.env.SYMPHONY_OPENCLAW_COMMAND || "openclaw");
  const executable = command[0];
  const baseArgs = command.slice(1);
  const args = baseArgs.concat([
    "message",
    "channel",
    "info",
    "--channel",
    process.env.SYMPHONY_OPENCLAW_CHANNEL || "discord",
    "--target",
    defaultTarget(channelId),
    "--json"
  ]);

  if (context.account || process.env.SYMPHONY_OPENCLAW_ACCOUNT) {
    args.splice(args.indexOf("--target"), 0, "--account", context.account || process.env.SYMPHONY_OPENCLAW_ACCOUNT);
  }

  const output = await execFileCapture(executable, args);
  const payload = parseJsonFromOutput(output.stdout);
  const channel = payload?.payload?.channel || payload?.channel;

  return String(channel?.parent_id || channel?.parentId || "");
}

function uniq(values) {
  const seen = new Set();
  const result = [];

  for (const value of values) {
    const normalized = String(value || "").trim();

    if (!normalized || seen.has(normalized)) {
      continue;
    }

    seen.add(normalized);
    result.push(normalized);
  }

  return result;
}

function defaultTarget(channelId) {
  return channelId ? `channel:${channelId}` : "";
}

function parseJsonArray(value) {
  if (!value) {
    return [];
  }

  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    return value.split(",").map((part) => part.trim()).filter(Boolean);
  }
}

async function readJson(response) {
  try {
    return await response.json();
  } catch (_error) {
    return null;
  }
}

function messageId(context) {
  const metadata = context.metadata || {};
  return metadata.messageId || metadata.id || metadata.message_id || "";
}

function senderName(context) {
  const metadata = context.metadata || {};
  return metadata.senderName || metadata.senderId || metadata.userName || metadata.userId || context.from || "";
}

async function sendReply(profile, context, message) {
  const resolvedProfile = profile || normalizeProfile({}, String(context.channelId || ""));
  const command = splitCommand(process.env.SYMPHONY_OPENCLAW_COMMAND || "openclaw");
  const executable = command[0];
  const baseArgs = command.slice(1);
  const args = baseArgs.concat(["message", "send", "--channel", resolvedProfile.channel || "discord"]);

  if (resolvedProfile.account) {
    args.push("--account", resolvedProfile.account);
  }

  args.push("--target", resolvedProfile.target || defaultTarget(String(context.channelId || "")));
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
      console.error(`[symphony-issue-intake] failed to send reply: ${error.message}`);
      resolve();
    });
    child.on("close", () => resolve());
  });
}

function execFileCapture(executable, args) {
  return new Promise((resolve) => {
    const child = spawn(executable, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      resolve({ code: 1, stdout, stderr: stderr || error.message });
    });

    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}
