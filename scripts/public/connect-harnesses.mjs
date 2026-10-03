#!/usr/bin/env node
// Registers Kronos's MCP bridge (Kronos.app/Contents/MacOS/kronos-mcp) with the local AI tools.
//   node scripts/private/connect-harnesses.mjs [--app /Applications/Kronos.app] [--dry-run]
// Idempotent: a file is only touched when its content would change, and is copied to
// <file>.bak-<timestamp> first. Edits to the TOML and YAML configs are TEXT edits so the rest
// of those files stays byte-identical. Never prints values from those files (they hold keys).
// A Kronos Demo.app registers as "kronos-demo" so it can never replace the real entry.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

const argv = process.argv.slice(2);
const dry = argv.includes("--dry-run");
const appArg = argv.includes("--app") ? argv[argv.indexOf("--app") + 1] : "/Applications/Kronos.app";
const app = path.resolve(appArg);
const bridge = path.join(app, "Contents/MacOS/kronos-mcp");
const name = /demo/i.test(path.basename(app)) ? "kronos-demo" : "kronos";
const home = process.env.HOME || os.homedir();
const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
const results = [];
const report = (who, status) => results.push(`${who.padEnd(14)} ${status}`);

if (!fs.existsSync(bridge)) { console.error(`kronos-mcp not found at ${bridge}`); process.exit(2); }

// Each AI tool gets its OWN token (secrets/agents/<slug>.token, 0600): Kronos then knows which agent wrote
// what and can limit, review or revoke it alone. The bridge reads it through `--agent <slug>`. A tool still
// configured without `--agent` keeps working on the shared token, with read and propose rights only.
const secretsDir = process.env.KRONOS_STORE_DIR
  ? path.join(process.env.KRONOS_STORE_DIR, "secrets")
  : path.join(home, "Library/Application Support", name === "kronos-demo" ? "Kronos Demo" : "Kronos", "secrets");

/** Creates the agent's token file when it is missing; returns a status phrase. Never prints the token. */
function ensureToken(slug) {
  const file = path.join(secretsDir, "agents", `${slug}.token`);
  if (fs.existsSync(file)) return "token kept";
  if (dry) return "would create token";
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.chmodSync(secretsDir, 0o700);
  fs.chmodSync(path.dirname(file), 0o700);
  fs.writeFileSync(file, crypto.randomBytes(32).toString("base64url"), { mode: 0o600 });
  return "token created";
}

function backup(file) {
  const dst = `${file}.bak-${stamp}`;
  fs.copyFileSync(file, dst);
  fs.chmodSync(dst, fs.statSync(file).mode & 0o777);
}

/** Writes `next` to `file` (backup first) unless identical. Returns the status word. */
function writeIfChanged(file, prev, next, created = false) {
  if (prev === next) return "already connected";
  if (dry) return created ? "would create" : "would update";
  if (!created) backup(file);
  else fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, next); // keeps the mode of an existing file
  return created ? "created" : (prev.includes(`${name}`) ? "updated" : "added");
}

// ---- Claude Code --------------------------------------------------------------------
function claudeCode() {
  // KRONOS_CLAUDE_BIN=none skips Claude Code (tests); a path picks that binary.
  const forced = process.env.KRONOS_CLAUDE_BIN;
  const bin = forced === "none" ? "" : forced || ["/opt/homebrew/bin/claude", `${home}/.local/bin/claude`, "/usr/local/bin/claude"].find(fs.existsSync)
    || (spawnSync("which", ["claude"], { encoding: "utf8" }).stdout || "").trim();
  if (!bin) return report("Claude Code", "skipped (claude not found)");
  const got = spawnSync(bin, ["mcp", "get", name], { encoding: "utf8" });
  const wired = got.status === 0 && (got.stdout || "").includes(bridge) && (got.stdout || "").includes("--agent claude-code");
  if (wired) return report("Claude Code", `already connected (${ensureToken("claude-code")})`);
  if (dry) return report("Claude Code", `would add (${ensureToken("claude-code")})`);
  const cfg = `${home}/.claude.json`;
  if (fs.existsSync(cfg)) backup(cfg);
  if (got.status === 0) spawnSync(bin, ["mcp", "remove", "-s", "user", name]);
  const tokenStatus = ensureToken("claude-code");
  const r = spawnSync(bin, ["mcp", "add", "-s", "user", name, "--", bridge, "--agent", "claude-code"], { encoding: "utf8" });
  report("Claude Code", r.status === 0 ? `${got.status === 0 ? "updated" : "added"} (${tokenStatus})` : `error (exit ${r.status})`);
}

// SessionStart hook: what the person did with this agent's tasks since it last asked, printed into the
// session's context at no cost to the person. Prints nothing when there is nothing to report or Kronos is off.
function claudeHook() {
  const file = `${home}/.claude/settings.json`;
  const command = `${JSON.stringify(bridge)} events --agent claude-code --format md --ack`;
  let prev = "", obj = {};
  if (fs.existsSync(file)) {
    prev = fs.readFileSync(file, "utf8");
    try { obj = prev.trim() ? JSON.parse(prev) : {}; } catch { return report("Claude Code hook", "error (settings.json is not valid JSON, left untouched)"); }
  }
  obj.hooks = obj.hooks && typeof obj.hooks === "object" ? obj.hooks : {};
  const list = Array.isArray(obj.hooks.SessionStart) ? obj.hooks.SessionStart : [];
  const mine = (h) => (h.hooks || []).some((x) => typeof x.command === "string" && x.command.includes("events --agent claude-code"));
  if (list.some(mine)) {
    // Same hook, maybe from another app path: point it at this bridge.
    const stale = list.some((h) => (h.hooks || []).some((x) => typeof x.command === "string" && x.command.includes("events --agent claude-code") && x.command !== command));
    if (!stale) return report("Claude Code hook", "already connected");
    for (const h of list) for (const x of h.hooks || []) {
      if (typeof x.command === "string" && x.command.includes("events --agent claude-code")) x.command = command;
    }
  } else {
    list.push({ hooks: [{ type: "command", command }] });
  }
  obj.hooks.SessionStart = list;
  report("Claude Code hook", writeIfChanged(file, prev, JSON.stringify(obj, null, 2) + "\n", !prev));
}

// ---- Codex (TOML, text edit) ---------------------------------------------------------
function codex() {
  const file = `${home}/.codex/config.toml`;
  if (!fs.existsSync(file)) return report("Codex", "skipped (no ~/.codex/config.toml)");
  const prev = fs.readFileSync(file, "utf8");
  const block = `[mcp_servers.${name}]\ncommand = ${JSON.stringify(bridge)}\nargs = ["--agent", "codex"]\nstartup_timeout_sec = 30\n`;
  const lines = prev.split("\n");
  const own = new RegExp(`^\\[mcp_servers\\.("?)${name}\\1(\\.[^\\]]*)?\\]\\s*$`);
  const start = lines.findIndex((l) => own.test(l));
  let next;
  if (start < 0) {
    next = prev + (prev.endsWith("\n") || !prev ? "" : "\n") + (prev ? "\n" : "") + block;
  } else {
    let end = start + 1;
    while (end < lines.length && !(/^\[/.test(lines[end]) && !own.test(lines[end]))) end++;
    // keep the blank line that separated this table from the next one
    while (end > start + 1 && lines[end - 1].trim() === "") end--;
    next = [...lines.slice(0, start), ...block.trimEnd().split("\n"), ...lines.slice(end)].join("\n");
  }
  report("Codex", `${writeIfChanged(file, prev, next)} (${ensureToken("codex")})`);
}


// ---- JSON clients --------------------------------------------------------------------
function jsonClient(who, file, { createIfAbsent, slug }) {
  const exists = fs.existsSync(file);
  if (!exists && !createIfAbsent) return report(who, "skipped (not installed)");
  let prev = "", obj = {};
  if (exists) {
    prev = fs.readFileSync(file, "utf8");
    try { obj = prev.trim() ? JSON.parse(prev) : {}; } catch { return report(who, "error (config is not valid JSON, left untouched)"); }
  }
  obj.mcpServers = obj.mcpServers && typeof obj.mcpServers === "object" ? obj.mcpServers : {};
  obj.mcpServers[name] = { command: bridge, args: ["--agent", slug] };
  report(who, `${writeIfChanged(file, prev, JSON.stringify(obj, null, 2) + "\n", !exists)} (${ensureToken(slug)})`);
}

claudeCode();
if (fs.existsSync(`${home}/.claude`)) claudeHook();
codex();
jsonClient("Claude Desktop", `${home}/Library/Application Support/Claude/claude_desktop_config.json`, { createIfAbsent: true, slug: "claude-desktop" });
if (fs.existsSync(`${home}/.cursor`)) jsonClient("Cursor", `${home}/.cursor/mcp.json`, { createIfAbsent: true, slug: "cursor" });
else report("Cursor", "skipped (no ~/.cursor)");

console.log(`Kronos bridge: ${bridge}${dry ? "  (dry run, nothing written)" : ""}`);
console.log(results.join("\n"));
