#!/usr/bin/env node
// ide-bridge: the IDE that Claude sees in the sandbox. It stands in for the plugin in the host's IDE, so
// that the file open there and the lines selected in it reach Claude as they do outside the sandbox.
//
// On the host, host/ide-relay.py listens to the real plugin and writes the latest selection to state.json,
// in a directory mounted here READ-ONLY (SANDBOX_IDE_DIR). This server, which launch.sh starts, speaks the
// plugin's protocol (MCP over a websocket on the loopback, found by Claude through ~/.claude/ide/<port>.lock
// and CLAUDE_CODE_SSE_PORT) and sends each change on. It has no tools: no IDE diffs, no diagnostics. And
// nothing Claude sends goes anywhere: there is no way from here to the host's IDE.
//
// No dependencies (plain Node, which the base image has): only the part of RFC 6455 this needs.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const PORT = Number(process.env.CLAUDE_CODE_SSE_PORT);
const STATE = path.join(process.env.SANDBOX_IDE_DIR || "/opt/ai-sandbox/ide", "state.json");
const LOCKS = path.join(process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME, ".claude"), "ide");
const LOCK = path.join(LOCKS, `${PORT}.lock`);
const TOKEN = crypto.randomUUID();
const POLL_MS = 200; // no inotify: bind mounts on macOS lack it
const MAX_MESSAGE = 16 * 1024 * 1024;
const PROTOCOL = "2024-11-05"; // the real plugin's

// The plugin's own name: Claude asks an IDE of any other name for diagnostics around every edit, which
// this one has none of.
const SERVER_INFO = { name: "Claude Code JetBrains Plugin", version: "0.0.0-ai-sandbox" };

// What clears the selection in Claude: no lines, no text, no file.
const NOTHING = { selection: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }, text: "" };

const clients = new Set();

const frame = (payload, opcode = 1) => {
  const size = payload.length;
  let head;
  if (size < 126) head = Buffer.from([0x80 | opcode, size]);
  else if (size < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode;
    head[1] = 126;
    head.writeUInt16BE(size, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x80 | opcode;
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(size), 2);
  }
  return Buffer.concat([head, payload]);
};
const send = (socket, msg) => socket.write(frame(Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...msg }))));

// ── The state the host writes ────────────────────────────────────────────────
let raw = "";
let state = { selection: null, mention: null, mentions: 0 };
const sendSelection = (socket) =>
  send(socket, { method: "selection_changed", params: state.selection ?? NOTHING });
const read = () => {
  let text;
  try {
    text = fs.readFileSync(STATE, "utf8");
  } catch {
    text = ""; // the relay has stopped, and taken the file with it
  }
  if (text === raw) return false;
  raw = text;
  try {
    state = text ? JSON.parse(text) : { selection: null, mention: null, mentions: state.mentions };
  } catch {
    return false;
  }
  return true;
};
read();
let mentions = state.mentions;
let selection = JSON.stringify(state.selection);
setInterval(() => {
  if (!read()) return;
  if (JSON.stringify(state.selection) !== selection) {
    selection = JSON.stringify(state.selection);
    for (const socket of clients) sendSelection(socket);
  }
  if (state.mentions > mentions) {
    mentions = state.mentions;
    for (const socket of clients) send(socket, { method: "at_mentioned", params: state.mention });
  }
}, POLL_MS);

// ── The MCP server ───────────────────────────────────────────────────────────
const handle = (socket, msg) => {
  // Claude listens for selections from when it has sent this; the one there is now goes out first.
  if (msg.method === "ide_connected") {
    clients.add(socket);
    sendSelection(socket);
  }
  if (msg.id === undefined || msg.method === undefined) return; // a notification, or a response
  switch (msg.method) {
    case "initialize":
      send(socket, {
        id: msg.id,
        result: { protocolVersion: PROTOCOL, capabilities: { tools: {} }, serverInfo: SERVER_INFO },
      });
      break;
    case "ping":
      send(socket, { id: msg.id, result: {} });
      break;
    case "tools/list":
      send(socket, { id: msg.id, result: { tools: [] } });
      break;
    default:
      send(socket, { id: msg.id, error: { code: -32601, message: `not available in the sandbox: ${msg.method}` } });
  }
};

// ── The websocket ────────────────────────────────────────────────────────────
const serve = (socket, head) => {
  let buffer = head;
  let parts = [];
  const drop = () => {
    clients.delete(socket);
    socket.destroy();
  };
  const take = () => {
    while (buffer.length >= 2) {
      let size = buffer[1] & 0x7f;
      let at = 2;
      if (size === 126) {
        if (buffer.length < 4) return;
        size = buffer.readUInt16BE(2);
        at = 4;
      } else if (size === 127) {
        if (buffer.length < 10) return;
        size = Number(buffer.readBigUInt64BE(2));
        at = 10;
      }
      if (size > MAX_MESSAGE || !(buffer[1] & 0x80)) return drop(); // a client's frames are masked
      if (buffer.length < at + 4 + size) return;
      const mask = buffer.subarray(at, at + 4);
      const payload = Buffer.from(buffer.subarray(at + 4, at + 4 + size));
      for (let i = 0; i < size; i++) payload[i] ^= mask[i % 4];
      const final = buffer[0] & 0x80;
      const opcode = buffer[0] & 0x0f;
      buffer = buffer.subarray(at + 4 + size);
      if (opcode === 8) return drop();
      if (opcode === 9) socket.write(frame(payload, 10));
      else if (opcode === 0 || opcode === 1) {
        parts.push(payload);
        if (!final) continue;
        const text = Buffer.concat(parts).toString("utf8");
        parts = [];
        try {
          handle(socket, JSON.parse(text));
        } catch (error) {
          console.error(`[sandbox-ide] ignored a message: ${error.message}`);
        }
      }
    }
  };
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    take();
  });
  socket.on("error", drop);
  socket.on("close", drop);
  take();
};

const server = http.createServer((_, response) => response.writeHead(404).end());
server.on("upgrade", (request, socket, head) => {
  const key = request.headers["sec-websocket-key"];
  // The token is this container's own, not the host IDE's. The loopback is already the container's, but a
  // nested container on its host network shares it.
  if (!key || request.headers["x-claude-code-ide-authorization"] !== TOKEN) {
    socket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return;
  }
  const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  const protocol = request.headers["sec-websocket-protocol"] ? "Sec-WebSocket-Protocol: mcp\r\n" : "";
  socket.write(
    `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n${protocol}\r\n`,
  );
  serve(socket, head);
});
server.on("error", (error) => {
  console.error(`[sandbox-ide] ${error.message}`);
  process.exit(1);
});
server.listen(PORT, "127.0.0.1", () => {
  fs.mkdirSync(LOCKS, { recursive: true });
  fs.writeFileSync(
    LOCK,
    JSON.stringify({
      workspaceFolders: [process.cwd(), "/work"],
      pid: process.pid,
      ideName: process.env.SANDBOX_IDE || "IDE",
      transport: "ws",
      runningInWindows: false,
      authToken: TOKEN,
    }),
    { mode: 0o600 },
  );
});
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"])
  process.on(signal, () => {
    fs.rmSync(LOCK, { force: true });
    process.exit(0);
  });
