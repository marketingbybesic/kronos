#!/usr/bin/env node
// Registers Kronos's MCP bridge (Kronos.app/Contents/MacOS/kronos-mcp) with the local AI tools.
//   node scripts/private/connect-harnesses.mjs [--app /Applications/Kronos.app] [--dry-run]
// Idempotent: a file is only touched when its content would change, and is copied to
// <file>.bak-<timestamp> first. Edits to Codex TOML and Hermes YAML are TEXT edits so the rest
// of those files stays byte-identical. Never prints values from those files (they hold keys).
// A Kronos Demo.app registers as "kronos-demo" so it can never replace the real entry.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
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
  const bin = ["/opt/homebrew/bin/claude", `${home}/.local/bin/claude`, "/usr/local/bin/claude"].find(fs.existsSync)
    || (spawnSync("which", ["claude"], { encoding: "utf8" }).stdout || "").trim();
  if (!bin) return report("Claude Code", "skipped (claude not found)");
  const got = spawnSync(bin, ["mcp", "get", name], { encoding: "utf8" });
  if (got.status === 0 && (got.stdout || "").includes(bridge)) return report("Claude Code", "already connected");
  if (dry) return report("Claude Code", "would add");
  const cfg = `${home}/.claude.json`;
  if (fs.existsSync(cfg)) backup(cfg);
  if (got.status === 0) spawnSync(bin, ["mcp", "remove", "-s", "user", name]);
  const r = spawnSync(bin, ["mcp", "add", "-s", "user", name, "--", bridge], { encoding: "utf8" });
  report("Claude Code", r.status === 0 ? (got.status === 0 ? "updated" : "added") : `error (exit ${r.status})`);
}

// ---- Codex (TOML, text edit) ---------------------------------------------------------
function codex() {
  const file = `${home}/.codex/config.toml`;
  if (!fs.existsSync(file)) return report("Codex", "skipped (no ~/.codex/config.toml)");
  const prev = fs.readFileSync(file, "utf8");
  const block = `[mcp_servers.${name}]\ncommand = ${JSON.stringify(bridge)}\nargs = []\nstartup_timeout_sec = 30\n`;
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
  report("Codex", writeIfChanged(file, prev, next));
}

// ---- Hermes (YAML, text edit) --------------------------------------------------------
function hermes() {
  const file = `${home}/.hermes/config.yaml`;
  if (!fs.existsSync(file)) return report("Hermes", "skipped (no ~/.hermes/config.yaml)");
  const prev = fs.readFileSync(file, "utf8");
  const entry = [`  ${name}:`, `    command: ${JSON.stringify(bridge)}`, `    args: []`, `    lazy: true`];
  const lines = prev.split("\n");
  const top = lines.findIndex((l) => /^mcp_servers:\s*(#.*)?$/.test(l));
  let next;
  if (top < 0) {
    next = prev + (prev.endsWith("\n") || !prev ? "" : "\n") + `mcp_servers:\n${entry.join("\n")}\n`;
  } else {
    // section ends at the next non-blank, non-comment line with zero indent
    let secEnd = top + 1;
    while (secEnd < lines.length && !(lines[secEnd].trim() && !/^\s/.test(lines[secEnd]) && !lines[secEnd].startsWith("#"))) secEnd++;
    const s = lines.slice(top + 1, secEnd).findIndex((l) => new RegExp(`^  ${name}:\\s*$`).test(l));
    if (s < 0) {
      next = [...lines.slice(0, top + 1), ...entry, ...lines.slice(top + 1)].join("\n");
    } else {
      const a = top + 1 + s;
      let b = a + 1;
      while (b < secEnd && (lines[b].trim() === "" || /^ {3,}/.test(lines[b]))) b++;
      while (b > a + 1 && lines[b - 1].trim() === "") b--;
      next = [...lines.slice(0, a), ...entry, ...lines.slice(b)].join("\n");
    }
  }
  report("Hermes", writeIfChanged(file, prev, next));
}

// ---- JSON clients --------------------------------------------------------------------
function jsonClient(who, file, { createIfAbsent }) {
  const exists = fs.existsSync(file);
  if (!exists && !createIfAbsent) return report(who, "skipped (not installed)");
  let prev = "", obj = {};
  if (exists) {
    prev = fs.readFileSync(file, "utf8");
    try { obj = prev.trim() ? JSON.parse(prev) : {}; } catch { return report(who, "error (config is not valid JSON, left untouched)"); }
  }
  obj.mcpServers = obj.mcpServers && typeof obj.mcpServers === "object" ? obj.mcpServers : {};
  obj.mcpServers[name] = { command: bridge };
  report(who, writeIfChanged(file, prev, JSON.stringify(obj, null, 2) + "\n", !exists));
}

claudeCode();
codex();
hermes();
jsonClient("Claude Desktop", `${home}/Library/Application Support/Claude/claude_desktop_config.json`, { createIfAbsent: true });
if (fs.existsSync(`${home}/.cursor`)) jsonClient("Cursor", `${home}/.cursor/mcp.json`, { createIfAbsent: true });
else report("Cursor", "skipped (no ~/.cursor)");

console.log(`Kronos bridge: ${bridge}${dry ? "  (dry run, nothing written)" : ""}`);
console.log(results.join("\n"));
