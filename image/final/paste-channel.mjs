#!/usr/bin/env node
// sandbox-paste: a Claude Code channel (an MCP server with the experimental claude/channel capability)
// that tells the running Claude session about each image `sandbox.sh paste-image` saves, so running the
// Paste Image run configuration is all it takes - no Ctrl+V of the path, and no cost until you paste.
//
// paste-image runs on the HOST and has no way into the sandbox (by design: see paste_image in
// sandbox.sh); it only drops a PNG into Claude's temporary directory, which the sandbox mounts. This
// server, which Claude starts with each session, watches that directory and pushes a
// notifications/claude/channel message for each new image, which Claude takes as a prompt.
//
// Each image goes to ONE session: with two Claude sessions in the sandbox (`attach`), both servers see
// it, and the one that creates pastes/.claimed/<name> first (an exclusive create) sends it. Images that
// were there when the session started are not offered (they belong to earlier sessions).
//
// No dependencies (plain Node, which the base image has): the MCP stdio transport is newline-delimited
// JSON-RPC, and this server needs only initialize, ping and an empty tools list.
import fs from "node:fs";
import path from "node:path";

const PASTES = path.join(process.env.CLAUDE_CODE_TMPDIR || "/opt/ai-sandbox/tmp", "pastes");
const CLAIMS = path.join(PASTES, ".claimed");
const POLL_MS = 1000; // a directory listing a second: no inotify, which bind mounts on macOS/Windows lack

// An older protocol revision on purpose: Claude Code drops channel notifications on a connection that
// negotiated the newest ("modern") one, which has no path for unsolicited server messages.
const PROTOCOL = "2025-06-18";

const send = (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...msg })}\n`);
const log = (text) => process.stderr.write(`[sandbox-paste] ${text}\n`);

const pngs = () => {
  try {
    return fs.readdirSync(PASTES).filter((name) => name.endsWith(".png"));
  } catch {
    return [];
  }
};
const seen = new Set(pngs());

const claim = (name) => {
  try {
    fs.mkdirSync(CLAIMS, { recursive: true });
    fs.closeSync(fs.openSync(path.join(CLAIMS, name), "wx"));
    return true;
  } catch {
    return false; // another session has it, or the directory is not writable
  }
};

let ready = false;
const poll = () => {
  if (!ready) return;
  for (const name of pngs()) {
    if (seen.has(name)) continue;
    seen.add(name);
    if (!claim(name)) continue;
    const file = path.join(PASTES, name);
    send({
      method: "notifications/claude/channel",
      params: {
        // Deliberately not "read it now": that turn re-sends the conversation anyway, so it is kept to one
        // line, and the image is read once the user says what it is for (their next message).
        content: `The user ran the Paste Image run configuration: the image is ${file}. Do NOT read it yet. Reply with one short line saying you have it and asking what they want done with it - unless their last message already said what the next pasted image is for, in which case read it and do that.`,
        meta: { path: file },
      },
    });
  }
};
setInterval(poll, POLL_MS);

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      log(`ignored a line that is not JSON: ${line.slice(0, 80)}`);
      continue;
    }
    if (msg.method === "notifications/initialized") ready = true;
    if (msg.id === undefined || msg.method === undefined) continue; // a notification, or a response
    switch (msg.method) {
      case "initialize":
        send({
          id: msg.id,
          result: {
            protocolVersion: PROTOCOL,
            capabilities: { experimental: { "claude/channel": {} }, tools: {} },
            serverInfo: { name: "sandbox-paste", version: "1.0.0" },
            instructions:
              "Messages from this channel say that the user has just run ai-sandbox's Paste Image: they name an image file to read.",
          },
        });
        break;
      case "ping":
        send({ id: msg.id, result: {} });
        break;
      case "tools/list":
        send({ id: msg.id, result: { tools: [] } });
        break;
      default:
        send({ id: msg.id, error: { code: -32601, message: `method not found: ${msg.method}` } });
    }
  }
});
process.stdin.on("end", () => process.exit(0));
