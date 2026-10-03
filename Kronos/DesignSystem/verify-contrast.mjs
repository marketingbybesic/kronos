#!/usr/bin/env node
// Gate: parses Tokens.swift, KColorSwatchPicker.swift and Accent.swift directly (never a
// hand-copied list) and computes real WCAG 2.1 contrast against pure OLED black (#000000),
// compositing opacity-based tokens in sRGB the way the renderer does. Prints a table and
// "CONTRAST OK" only if every assertion passes; exits 1 otherwise.
//
// Assertions:
//  - text tiers over #000: primary >= 7, secondary/tertiary >= 4.5 (and the same for each
//    tier's Increase Contrast value); focus ring >= 3, active border >= 3; chrome tokens neutral.
//  - primary/secondary/tertiary text on EVERY surface it can sit on: hover, selected, pressed
//    fills, every project/accent swatch tinted at the selection opacity, and under Increase
//    Contrast the IC selected fill and IC tint (with the tier's IC alpha) — all >= the tier floor.
//  - every project and accent swatch: >= 3 as a bar, >= 3 as a ring at the opacity it is drawn at
//    (Tok.ringAccentOpacity), >= 4.5 for the label Accent.onFill picks (the WCAG winner of
//    black/white), and no hue in the red band (< 20 or > 340 degrees).
//  - no decoration tier (textDisabled, glyphEmpty) on readable text anywhere in Kronos/
//    (runs scripts/design/verify-text-tiers.mjs; its success token is required).
// Decorative hairlines/fills are exempt but listed as such.
// Usage: node Kronos/DesignSystem/verify-contrast.mjs [--self-test]
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const read = (n) => readFileSync(join(here, n), "utf8");

const srgbToLin = (v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const lum = ([r, g, b]) => 0.2126 * srgbToLin(r / 255) + 0.7152 * srgbToLin(g / 255) + 0.0722 * srgbToLin(b / 255);
const ratio = (a, b) => { const la = lum(a), lb = lum(b); return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05); };
const BLACK = [0, 0, 0];
const hexRgb = (h) => { const n = parseInt(h, 16); return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]; };
const over = (fg, a, bg) => fg.map((v, i) => v * a + bg[i] * (1 - a));   // sRGB "source over"
const white = (a) => [255 * a, 255 * a, 255 * a];
function hueOf([r, g, b]) {
  const [rn, gn, bn] = [r / 255, g / 255, b / 255];
  const max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn), d = max - min;
  if (d === 0) return 0;
  let h = max === rn ? ((gn - bn) / d) % 6 : max === gn ? (bn - rn) / d + 2 : (rn - gn) / d + 4;
  h *= 60;
  return h < 0 ? h + 360 : h;
}

/// Runs every colour assertion on the given sources. Returns { rows, failed }.
function check({ tokensSrc, paletteSrc, accentSrc }) {
  const rows = [];
  let failed = 0;
  const fail = (name, r, msg) => { failed++; rows.push([name, r, `FAIL: ${msg}`]); };
  const pass = (name, r, msg) => rows.push([name, r, msg]);
  const need = (cond, what) => { if (!cond) { failed++; rows.push([what, "", "FAIL: not found in source — regex out of sync"]); } return cond; };

  // `public static let X = Color(white: 1, opacity: a)` / `Color.white.opacity(a)` /
  // `Color(hex: 0x...)` / `KTone.white(a, increasedContrast: b)`.
  const tokens = new Map();
  for (const m of tokensSrc.matchAll(/public static let (\w+)\s*=\s*(?:Color\(white:\s*1,\s*opacity:\s*([\d.]+)\)|Color\.white\.opacity\(([\d.]+)\)|Color\(hex:\s*0x([0-9A-Fa-f]{6})\)|KTone\.white\(([\d.]+),\s*increasedContrast:\s*([\d.]+)\))/g)) {
    const [, name, a1, a2, hex, ka, kic] = m;
    if (hex) tokens.set(name, { kind: "hex", rgb: hexRgb(hex) });
    else if (ka) tokens.set(name, { kind: "alpha", a: +ka, ic: +kic });
    else tokens.set(name, { kind: "alpha", a: +(a1 ?? a2) });
  }
  const dbl = (name) => { const m = tokensSrc.match(new RegExp(`static let ${name}\\s*:\\s*Double\\s*=\\s*([\\d.]+)`)); return m ? +m[1] : null; };
  const palette = [...paletteSrc.matchAll(/\("(\w+)",\s*"[0-9A-Fa-f]{6}",\s*Color\(hex:\s*0x([0-9A-Fa-f]{6})\)\)/g)].map((m) => ({ name: `project.${m[1]}`, rgb: hexRgb(m[2]) }));
  const accBlock = accentSrc.slice(accentSrc.indexOf("enum AccentPalette"));
  const accents = [...accBlock.slice(0, accBlock.indexOf("\n    ]")).matchAll(/\(\s*"(\w+)"\s*,\s*"([0-9A-Fa-f]{6})"\s*\)/g)].map((m) => ({ name: `accent.${m[1]}`, rgb: hexRgb(m[2]) }));

  const ringOp = dbl("ringAccentOpacity"), ringFloor = dbl("ringContrastFloor") ?? 3;
  const tintOp = dbl("selectedTintOpacity"), tintOpIC = dbl("selectedTintOpacityIC");
  if (!need(palette.length > 0, "KProjectPalette") | !need(accents.length > 0, "AccentPalette") |
      !need(ringOp !== null, "ringAccentOpacity") | !need(tintOp !== null, "selectedTintOpacity") |
      !need(tintOpIC !== null, "selectedTintOpacityIC")) return { rows, failed };
  for (const t of ["textPrimary", "textSecondary", "textTertiary", "hoverFill", "selectedFill", "pressedFill", "selectedFillIC"]) {
    if (!need(tokens.has(t), t)) return { rows, failed };
  }

  // 1. Every token on #000.
  const floors = { textPrimary: 7, textSecondary: 4.5, textTertiary: 4.5, focusRing: 3, borderActive: 3 };
  const exempt = new Set(["hairline", "borderControl", "borderStrong", "textDisabled", "glyphEmpty", "hoverFill", "pressedFill",
    "selectedFill", "selectedEdge", "selectedFillIC", "dropFill", "controlFill", "keycapFill", "tagFill"]);
  for (const [name, t] of tokens) {
    const rgb = t.kind === "hex" ? t.rgb : white(t.a);
    const sat = Math.max(...rgb) === 0 ? 0 : (Math.max(...rgb) - Math.min(...rgb)) / Math.max(...rgb);
    const r = ratio(rgb, BLACK).toFixed(2);
    if (sat > 0.12 && Math.max(...rgb) > 40) { fail(name, r, `chrome token is not neutral (hue ${hueOf(rgb).toFixed(0)}°)`); continue; }
    if (exempt.has(name)) { pass(name, r, "exempt (decorative/fill/non-text)"); continue; }
    const floor = floors[name];
    if (!floor) { pass(name, r, "informational (no assigned floor)"); continue; }
    if (+r < floor) fail(name, r, `< ${floor}`); else pass(name, r, `PASS >= ${floor}`);
    if (t.ic !== undefined) {
      const ri = ratio(white(t.ic), BLACK);
      if (ri < floor) fail(`${name}.ic`, ri.toFixed(2), `< ${floor}`); else pass(`${name}.ic`, ri.toFixed(2), `PASS >= ${floor} (Increase Contrast)`);
    }
  }

  // 2. Text tiers on every surface they can sit on (normal and Increase Contrast).
  rows.push(["", "", ""], ["-- text on state fills and tints --", "", ""]);
  const alpha = (n) => tokens.get(n).a;
  const fills = [["black", BLACK], ["hover", white(alpha("hoverFill"))], ["selected", white(alpha("selectedFill"))], ["pressed", white(alpha("pressedFill"))]];
  for (const s of [...palette, ...accents]) fills.push([`tint ${s.name}`, over(s.rgb, tintOp, BLACK)]);
  const icFills = [["IC selected", white(alpha("selectedFillIC"))]];
  for (const s of [...palette, ...accents]) icFills.push([`IC tint ${s.name}`, over(s.rgb, tintOpIC, BLACK)]);
  for (const tier of ["textPrimary", "textSecondary", "textTertiary"]) {
    const t = tokens.get(tier), floor = floors[tier];
    let worst = null;
    for (const [fname, bg] of fills) {
      const r = ratio(over([255, 255, 255], t.a, bg), bg);
      if (!worst || r < worst.r) worst = { r, fname };
      if (r < floor) fail(`${tier} on ${fname}`, r.toFixed(2), `< ${floor}`);
    }
    pass(`${tier} worst normal`, worst.r.toFixed(2), `on ${worst.fname}`);
    const ica = t.ic ?? t.a;
    let worstIC = null;
    for (const [fname, bg] of icFills) {
      const r = ratio(over([255, 255, 255], ica, bg), bg);
      if (!worstIC || r < worstIC.r) worstIC = { r, fname };
      if (r < floor) fail(`${tier} (IC ${ica}) on ${fname}`, r.toFixed(2), `< ${floor}`);
    }
    pass(`${tier} worst IC`, worstIC.r.toFixed(2), `on ${worstIC.fname} (alpha ${ica})`);
  }

  // 2b. Increase Contrast maps tertiary and disabled text to the secondary tone.
  rows.push(["", "", ""], ["-- Increase Contrast: tertiary and disabled map to secondary --", "", ""]);
  const secondary = tokens.get("textSecondary").a;
  for (const t of ["textTertiary", "textDisabled"]) {
    const ic = tokens.get(t)?.ic;
    if (ic === secondary) pass(`${t} @IC`, ic, "PASS equals textSecondary");
    else fail(`${t} @IC`, ic ?? "", `Increase Contrast alpha ${ic} is not the secondary alpha ${secondary}`);
  }

  // 3. Every swatch as an accent/project colour: bar, ring at its drawn opacity, label, hue.
  rows.push(["", "", ""], ["-- swatches: bar / ring @" + ringOp + " / label --", "", ""]);
  for (const s of [...palette, ...accents]) {
    const bar = ratio(s.rgb, BLACK), ring = ratio(over(s.rgb, ringOp, BLACK), BLACK);
    const black = ratio(s.rgb, BLACK), whiteL = ratio(s.rgb, [255, 255, 255]);
    const label = Math.max(black, whiteL), hue = hueOf(s.rgb);
    const msgs = [];
    if (bar < 3) msgs.push(`bar ${bar.toFixed(2)} < 3`);
    if (ring < ringFloor) msgs.push(`ring ${ring.toFixed(2)} < ${ringFloor} at ${ringOp}`);
    if (label < 4.5) msgs.push(`label ${label.toFixed(2)} < 4.5`);
    if (hue < 20 || hue > 340) msgs.push(`hue ${hue.toFixed(0)}° in the red band`);
    if (msgs.length) fail(s.name, bar.toFixed(2), msgs.join("; "));
    else pass(s.name, bar.toFixed(2), `PASS ring ${ring.toFixed(2)}, label ${label.toFixed(2)} (${black >= whiteL ? "black" : "white"}), hue ${hue.toFixed(0)}°`);
  }
  return { rows, failed };
}

/// Decoration tiers on readable text: delegated to the design tool so the rule lives in one place.
function textTierLint(paths = []) {
  const tool = join(repoRoot, "scripts/design/verify-text-tiers.mjs");
  if (!existsSync(tool)) return { ok: false, out: "FAIL: scripts/design/verify-text-tiers.mjs not found" };
  const r = spawnSync(process.execPath, [tool, ...paths], { cwd: repoRoot, encoding: "utf8" });
  const out = (r.stdout + r.stderr).trim();
  return { ok: r.status === 0 && /TEXTTIER OK/.test(out), out };
}

const sources = () => ({ tokensSrc: read("Tokens.swift"), paletteSrc: read("KColorSwatchPicker.swift"), accentSrc: read("Accent.swift") });

if (process.argv.includes("--self-test")) {
  // Each planted defect must make the gate fail; the untouched sources must pass.
  const base = sources();
  const mutate = (re, to) => { const s = { ...base }; const before = s.tokensSrc; s.tokensSrc = s.tokensSrc.replace(re, to); if (s.tokensSrc === before) throw new Error(`mutation did not apply: ${re}`); return s; };
  const cases = [
    ["tertiary 0.47 fails on the selected fill", mutate(/KTone\.white\(0\.52,\s*increasedContrast:\s*0\.66\)/, "KTone.white(0.47, increasedContrast: 0.66)")],
    ["tertiary without its IC step fails on the IC fill", mutate(/KTone\.white\(0\.52,\s*increasedContrast:\s*0\.66\)/, "KTone.white(0.52, increasedContrast: 0.52)")],
    ["disabled without its IC step fails the secondary mapping", mutate(/KTone\.white\(0\.30,\s*increasedContrast:\s*0\.66\)/, "KTone.white(0.30, increasedContrast: 0.30)")],
    ["electric fails as a ring at 0.65", mutate(/ringAccentOpacity:\s*Double\s*=\s*[\d.]+/, "ringAccentOpacity: Double = 0.65")],
  ];
  let ok = 0;
  if (check(base).failed !== 0) { console.error("SELFTEST: the real sources fail"); process.exit(1); }
  for (const [name, src] of cases) {
    const r = check(src);
    if (r.failed > 0) ok++; else console.error(`SELFTEST: not caught: ${name}`);
  }
  const lint = textTierLint([join(repoRoot, "scripts/design/fixtures/tiers-bad.swift")]);
  if (!lint.ok) ok++; else console.error("SELFTEST: not caught: decoration tier on Text");
  if (ok !== cases.length + 1) process.exit(1);
  console.log(`CONTRAST SELFTEST OK cases=${ok}`);
  process.exit(0);
}

const { rows, failed } = check(sources());
const w = Math.max(...rows.map((r) => r[0].length)) + 2;
for (const [name, r, verdict] of rows) console.log(r ? `${name.padEnd(w)} ${String(r).padStart(6)}:1  ${verdict}` : name);
const lint = textTierLint();
console.log(`text-tier lint: ${lint.out.split("\n").pop()}`);
if (!lint.ok) { console.error(lint.out); }
if (failed > 0 || !lint.ok) {
  console.error(`FAIL: ${failed} colour assertion(s)${lint.ok ? "" : " + text-tier lint"}`);
  process.exit(1);
}
console.log("CONTRAST OK");
