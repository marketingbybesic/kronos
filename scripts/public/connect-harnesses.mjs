#!/usr/bin/env node
// Registers Kronos's MCP bridge (Kronos.app/Contents/MacOS/kronos-mcp) with the AI tools installed on this Mac.
//   node scripts/public/connect-harnesses.mjs [--app /Applications/Kronos.app] [--dry-run]
// Only tools that are actually installed (their config folder or binary exists) are touched.
// Idempotent: a file is only written when its content would change, and is copied to
// <file>.bak-<timestamp> first. JSON configs are MERGED: every other server and every unknown field
// (also inside an existing kronos entry) is kept. TOML and YAML configs are TEXT edits so the rest of
// the file stays byte-identical. Never prints values from those files (they hold keys).
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
const report = (who, status) => results.push(`${who.padEnd(22)} ${status}`);

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
function writeIfChanged(file, prev, next, created = false, existed = prev.includes(name)) {
  if (prev === next) return "already connected";
  if (dry) return created ? "would create" : "would update";
  if (!created) backup(file);
  else fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, next); // keeps the mode of an existing file
  return created ? "created" : (existed ? "updated" : "added");
}

// ---- Detection -----------------------------------------------------------------------
// A harness counts as installed when one of its config dirs, binaries (PATH, Homebrew, ~/.local/bin)
// or .app bundles exists.
const exists = (p) => fs.existsSync(p);
const H = (...p) => path.join(home, ...p);
const appDirs = (process.env.KRONOS_APPS_DIRS ? process.env.KRONOS_APPS_DIRS.split(":") : ["/Applications", H("Applications")]).filter(Boolean);
function onPath(bin) {
  const dirs = (process.env.PATH || "").split(":").filter(Boolean);
  const extra = process.env.KRONOS_NO_EXTRA_PATH ? [] : ["/opt/homebrew/bin", "/usr/local/bin", H(".local/bin")];
  return [...dirs, ...extra].some((d) => { try { fs.accessSync(path.join(d, bin), fs.constants.X_OK); return true; } catch { return false; } });
}
function installed(d) {
  return (d.dirs || []).some(exists) || (d.bins || []).some(onPath) || (d.apps || []).some((a) => appDirs.some((dir) => exists(path.join(dir, a))));
}

// ---- JSON(C) helpers -----------------------------------------------------------------
/** Parses JSON that may carry // and /* comments or trailing commas (VS Code, Zed, opencode). */
function parseJsonc(text) {
  let out = "", comments = false, i = 0, inStr = false;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (inStr) { out += c; if (c === "\\") { out += n ?? ""; i += 2; continue; } if (c === '"') inStr = false; i++; continue; }
    if (c === '"') { inStr = true; out += c; i++; continue; }
    if (c === "/" && n === "/") { comments = true; while (i < text.length && text[i] !== "\n") i++; continue; }
    if (c === "/" && n === "*") { comments = true; i += 2; while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i += 2; continue; }
    if (c === ",") { let j = i + 1; while (/\s/.test(text[j] || "")) j++; if (text[j] === "}" || text[j] === "]") { i++; continue; } }
    out += c; i++;
  }
  return { value: JSON.parse(out.trim() ? out : "{}"), comments };
}
const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
const sorted = (o) => JSON.stringify(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : 1)));
function indentOf(text) {
  const m = /^([ \t]+)"/m.exec(text);
  return m ? m[1] : "  ";
}

/** Merge-writes mcp-style JSON: obj[key][name] = {...defaults, ...existing, ...want}. */
function jsonClient(h) {
  const slug = h.slug;
  const file = h.file();
  const present = exists(file);
  let prev = "", obj = {}, comments = false;
  if (present) {
    prev = fs.readFileSync(file, "utf8");
    try { ({ value: obj, comments } = parseJsonc(prev)); } catch { return report(h.who, "error (config is not valid JSON, left untouched)"); }
    if (!isObj(obj)) return report(h.who, "error (config is not a JSON object, left untouched)");
  } else obj = { ...(h.create || {}) };
  const section = isObj(obj[h.key]) ? obj[h.key] : {};
  const old = section[name];
  const want = h.entry(slug);
  const merged = { ...(h.defaults || {}), ...(isObj(old) ? old : {}), ...want };
  if (present && isObj(old) && sorted(old) === sorted(merged)) {
    return report(h.who, `already connected (${ensureToken(slug)})`);
  }
  if (present && comments) {
    return report(h.who, `skipped (config has comments, add "${name}" under ${h.key} by hand: ${JSON.stringify(want)})`);
  }
  obj[h.key] = { ...section, [name]: merged };
  const nl = !present || prev.endsWith("\n") ? "\n" : "";
  const next = JSON.stringify(obj, null, indentOf(prev)) + nl;
  const status = writeIfChanged(file, prev, next, !present, isObj(old));
  report(h.who, `${status} (${ensureToken(slug)})`);
}

// ---- Text-edited YAML (Goose extensions and other YAML configs) -------------------------
function yamlClient(h) {
  const file = h.file();
  const present = exists(file);
  const prev = present ? fs.readFileSync(file, "utf8") : "";
  const entry = h.entry(name);
  const lines = prev.split("\n");
  const topRe = new RegExp(`^${h.key}:\\s*(#.*)?$`);
  const top = lines.findIndex((l) => topRe.test(l));
  let next;
  if (top < 0) {
    next = prev + (prev.endsWith("\n") || !prev ? "" : "\n") + `${h.key}:\n${entry.join("\n")}\n`;
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
  report(h.who, `${writeIfChanged(file, prev, next, !present)} (${ensureToken(h.slug)})`);
}

// ---- Codex (TOML, text edit) ---------------------------------------------------------
function codex(h) {
  const file = h.file();
  const present = exists(file);
  const prev = present ? fs.readFileSync(file, "utf8") : "";
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
  report(h.who, `${writeIfChanged(file, prev, next, !present)} (${ensureToken("codex")})`);
}

// ---- Claude Code (CLI) ---------------------------------------------------------------
function claudeCode() {
  // KRONOS_CLAUDE_BIN=none skips Claude Code (tests); a path picks that binary.
  const forced = process.env.KRONOS_CLAUDE_BIN;
  const bin = forced === "none" ? "" : forced || ["/opt/homebrew/bin/claude", `${home}/.local/bin/claude`, "/usr/local/bin/claude"].find(exists)
    || (spawnSync("which", ["claude"], { encoding: "utf8" }).stdout || "").trim();
  if (!bin) return report("Claude Code", "skipped (not installed)");
  const got = spawnSync(bin, ["mcp", "get", name], { encoding: "utf8" });
  const wired = got.status === 0 && (got.stdout || "").includes(bridge) && (got.stdout || "").includes("--agent claude-code");
  if (wired) return report("Claude Code", `already connected (${ensureToken("claude-code")})`);
  if (dry) return report("Claude Code", `would add (${ensureToken("claude-code")})`);
  const cfg = `${home}/.claude.json`;
  if (exists(cfg)) backup(cfg);
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
  if (exists(file)) {
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
  report("Claude Code hook", writeIfChanged(file, prev, JSON.stringify(obj, null, indentOf(prev)) + "\n", !prev));
}

// ---- The table -----------------------------------------------------------------------
// One row per harness: how to detect it and which writer/format it needs. Formats: pi
// {mcpServers:{n:{command,args,exposure,...}}}, opencode {mcp:{n:{type:"local",command:[...],enabled}}}
// (command is ONE array), Zed {context_servers:{n:{command,args}}} in JSONC, Goose config.yaml
// extensions (cmd + args + type stdio), Gemini {mcpServers:{n:{command,args}}},
// VS Code {servers:{n:{type:"stdio",command,args}}}.
const std = (slug) => ({ command: bridge, args: ["--agent", slug] });
const CODE_USER = H("Library/Application Support/Code/User");
const HARNESSES = [
  { who: "Claude Code", run: () => claudeCode(), always: true },
  { who: "Codex", slug: "codex", writer: codex, detect: { dirs: [H(".codex")], bins: ["codex"] }, file: () => H(".codex/config.toml") },
  { who: "pi", slug: "pi", writer: jsonClient, detect: { dirs: [H(".pi/agent")], bins: ["pi"] }, file: () => H(".pi/agent/mcp.json"), key: "mcpServers", entry: std },
  { who: "opencode", slug: "opencode", writer: jsonClient, detect: { dirs: [H(".config/opencode")], bins: ["opencode"] },
    file: () => [H(".config/opencode/opencode.json"), H(".config/opencode/opencode.jsonc")].find(exists) || H(".config/opencode/opencode.json"),
    key: "mcp", entry: (slug) => ({ type: "local", command: [bridge, "--agent", slug] }), defaults: { enabled: true }, create: { $schema: "https://opencode.ai/config.json" } },
  { who: "Gemini CLI", slug: "gemini", writer: jsonClient, detect: { dirs: [H(".gemini")], bins: ["gemini"] }, file: () => H(".gemini/settings.json"), key: "mcpServers", entry: std },
  { who: "Windsurf", slug: "windsurf", writer: jsonClient, detect: { dirs: [H(".codeium/windsurf")], apps: ["Windsurf.app"] }, file: () => H(".codeium/windsurf/mcp_config.json"), key: "mcpServers", entry: std },
  { who: "Zed", slug: "zed", writer: jsonClient, detect: { dirs: [H(".config/zed")], bins: ["zed"], apps: ["Zed.app"] }, file: () => H(".config/zed/settings.json"), key: "context_servers", entry: std },
  { who: "Cline", slug: "cline", writer: jsonClient, detect: { dirs: [path.join(CODE_USER, "globalStorage/saoudrizwan.claude-dev")] },
    file: () => path.join(CODE_USER, "globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"), key: "mcpServers", entry: std },
  { who: "Roo Code", slug: "roo", writer: jsonClient, detect: { dirs: [path.join(CODE_USER, "globalStorage/rooveterinaryinc.roo-cline")] },
    file: () => path.join(CODE_USER, "globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json"), key: "mcpServers", entry: std },
  { who: "VS Code", slug: "vscode", writer: jsonClient, detect: { dirs: [CODE_USER], bins: ["code"] }, file: () => path.join(CODE_USER, "mcp.json"), key: "servers", entry: (slug) => ({ type: "stdio", ...std(slug) }) },
  { who: "Cursor", slug: "cursor", writer: jsonClient, detect: { dirs: [H(".cursor")], bins: ["cursor"], apps: ["Cursor.app"] }, file: () => H(".cursor/mcp.json"), key: "mcpServers", entry: std },
  { who: "Claude Desktop", slug: "claude-desktop", writer: jsonClient, detect: { dirs: [H("Library/Application Support/Claude")], apps: ["Claude.app"] },
    file: () => H("Library/Application Support/Claude/claude_desktop_config.json"), key: "mcpServers", entry: std },
  { who: "Goose", slug: "goose", writer: yamlClient, detect: { dirs: [H(".config/goose")], bins: ["goose"] }, file: () => H(".config/goose/config.yaml"), key: "extensions",
    entry: (n) => [`  ${n}:`, "    enabled: true", "    type: stdio", `    name: ${n}`, `    cmd: ${JSON.stringify(bridge)}`, `    args: ["--agent", "goose"]`, "    envs: {}", "    timeout: 300"] },
];

for (const h of HARNESSES) {
  if (!h.always && !installed(h.detect)) { report(h.who, "skipped (not installed)"); continue; }
  if (h.run) h.run(); else h.writer(h);
  if (h.who === "Claude Code" && exists(H(".claude"))) claudeHook();
}


// Unknown agents: report config files that look like MCP configs but have no writer here. Never written.
{
  const known = new Set(HARNESSES.filter((h) => h.file).map((h) => h.file()));
  const found = [];
  const scan = (dir, re) => { try { for (const e of fs.readdirSync(dir)) if (re.test(e)) found.push(path.join(dir, e)); } catch {} };
  try { for (const d of fs.readdirSync(home)) if (d.startsWith(".") && d.length > 1) scan(path.join(home, d), /^mcp\.json$/); } catch {}
  try { for (const d of fs.readdirSync(H(".config"))) scan(path.join(H(".config"), d), /^mcp.*\.json$/); } catch {}
  for (const f of found.filter((f) => !known.has(f)).sort()) report("Other", `found but format unknown, not touched: ${f.replace(home, "~")}`);
}

console.log(`Kronos bridge: ${bridge}${dry ? "  (dry run, nothing written)" : ""}`);
console.log(results.join("\n"));
