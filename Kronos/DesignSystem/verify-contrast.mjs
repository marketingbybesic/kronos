#!/usr/bin/env node
// Gate: parses Tokens.swift AND KColorSwatchPicker.swift directly (never a hand-copied
// list) and computes real WCAG 2.1 contrast against pure OLED black (#000000),
// compositing opacity-based tokens over black. Prints a table and "CONTRAST OK" only
// if every assertion passes; exits 1 otherwise.
//
// Assertions: primary text >= 7, secondary/tertiary text >= 4.5, focus ring >= 3,
// active border >= 3, project-colour swatches >= 3 (dots/fills, not text) AND no
// swatch hue falls in the red range: no red/red-adjacent anywhere.
// Decorative hairlines/fills are exempt but listed as such.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "Tokens.swift"), "utf8");
const paletteSrc = readFileSync(join(here, "KColorSwatchPicker.swift"), "utf8");

// Parse `public static let <name> = Color(white: 1, opacity: <alpha>)` and
// `public static let <name> = Color(hex: 0x......)` declarations from the real source.
const tokens = [];
const lineRe = /public static let (\w+)\s*=\s*Color\((white:\s*1,\s*opacity:\s*([\d.]+)|hex:\s*0x([0-9A-Fa-f]{6}))\)/g;
let m;
while ((m = lineRe.exec(src))) {
  const [, name, , alpha, hex] = m;
  if (alpha !== undefined) tokens.push({ name, kind: "alpha", alpha: parseFloat(alpha) });
  else if (hex !== undefined) tokens.push({ name, kind: "hex", hex });
}
// Also catch tokens defined as aliases of another token (e.g. `focusRing = accentText`)
// so they're covered without duplicating a color literal.
const aliasRe = /public static let (\w+)\s*=\s*(\w+)\s*$/gm;
while ((m = aliasRe.exec(src))) {
  const [, name, ref] = m;
  const target = tokens.find((t) => t.name === ref);
  if (target && !tokens.some((t) => t.name === name)) tokens.push({ ...target, name });
}

// Parse the project-colour palette: ("name", "hex", Color(hex: 0x......)) tuples. This is
// the ONLY place hue is allowed in the app (user data — project identity, and the accent
// personalisation colour reuses the same 12), so it gets its own contrast floor AND a
// hue-range rejection.
const palette = [];
const paletteRe = /\("(\w+)",\s*"[0-9A-Fa-f]{6}",\s*Color\(hex:\s*0x([0-9A-Fa-f]{6})\)\)/g;
while ((m = paletteRe.exec(paletteSrc))) {
  const [, name, hex] = m;
  palette.push({ name: `palette.${name}`, kind: "hex", hex });
}
tokens.push(...palette);

const srgbToLin = (v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const luminance = (r, g, b) => 0.2126 * srgbToLin(r / 255) + 0.7152 * srgbToLin(g / 255) + 0.0722 * srgbToLin(b / 255);
const contrastVsBlack = (r, g, b) => (luminance(r, g, b) + 0.05) / 0.05;

function rgbOf(tok) {
  if (tok.kind === "hex") {
    const n = parseInt(tok.hex, 16);
    return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  }
  // white at `alpha` composited over pure black = (255*alpha, 255*alpha, 255*alpha)
  const v = Math.round(255 * tok.alpha);
  return [v, v, v];
}

// Hue in degrees [0, 360). Used only for the palette's red-range rejection.
function hueOf(r, g, b) {
  const [rn, gn, bn] = [r / 255, g / 255, b / 255];
  const max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn), d = max - min;
  if (d === 0) return 0;
  let h;
  if (max === rn) h = ((gn - bn) / d) % 6;
  else if (max === gn) h = (bn - rn) / d + 2;
  else h = (rn - gn) / d + 4;
  h *= 60;
  return h < 0 ? h + 360 : h;
}

// Role classification drives which floor applies. Everything not listed is checked
// informationally (printed, not gated) except explicit exemptions. Chrome is fully
// monochrome now — the only hue-bearing roles left are the palette swatches below and
// destructiveLabel (macOS's own system red for a menu's "Delete" word, never ambient
// chrome — see Tokens.swift's comment on it).
const roles = {
  textPrimary: { floor: 7, label: "primary text" },
  textSecondary: { floor: 4.5, label: "secondary text" },
  textTertiary: { floor: 4.5, label: "tertiary/placeholder text" },
  focusRing: { floor: 3, label: "focus ring" },
  borderActive: { floor: 3, label: "active border" },
  destructiveLabel: { floor: 4.5, label: "destructive menu label (system red, text only)" },
};
const exempt = new Set(["hairline", "borderControl", "borderStrong", "bg", "surface", "raised", "overlay",
  "textDisabled", "textOnAccent", "hoverFill", "pressedFill", "selectedFill", "dropFill"]);

let failed = 0;
const rows = [];
for (const tok of tokens) {
  const [r, g, b] = rgbOf(tok);
  const ratio = contrastVsBlack(r, g, b);
  const isPalette = tok.name.startsWith("palette.");
  const role = isPalette ? { floor: 3, label: "project-colour swatch (dot/fill)" } : roles[tok.name];
  // Chrome tokens must be NEUTRAL: any non-palette token with real saturation is a colour
  // that crept into the chrome — checked before exemptions so a "decorative" label cannot
  // hide a red. Palette swatches are user data and are hue-checked below.
  if (!isPalette) {
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const sat = max === 0 ? 0 : (max - min) / max;
    if (sat > 0.12 && max > 40) {
      failed++;
      rows.push([tok.name, ratio.toFixed(2), `FAIL: chrome token is not neutral (saturation ${sat.toFixed(2)}, hue ${hueOf(r, g, b).toFixed(0)}°)`]);
      continue;
    }
  }
  if (exempt.has(tok.name)) {
    rows.push([tok.name, ratio.toFixed(2), "exempt (decorative/fill/non-text)"]);
    continue;
  }
  if (!role) {
    rows.push([tok.name, ratio.toFixed(2), "informational (no assigned floor)"]);
    continue;
  }
  let pass = ratio >= role.floor;
  let verdict = `${pass ? "PASS" : "FAIL"} >= ${role.floor} (${role.label})`;
  if (isPalette) {
    const hue = hueOf(r, g, b);
    const isRed = hue < 20 || hue > 340;
    if (isRed) { pass = false; verdict += ` — FAIL: hue ${hue.toFixed(0)}° is red/red-adjacent, forbidden`; }
    else verdict += ` hue ${hue.toFixed(0)}°`;
  }
  if (!pass) failed++;
  rows.push([tok.name, ratio.toFixed(2), verdict]);
}

// Accent (feature H): the user-chosen personalisation colour is one of the 12 palette
// swatches, or white (Tok.textPrimary — the default, proven above as `textPrimary`).
// It is used in exactly two shapes: a FILL with a black/white label on top (primary
// button, toggle on-state's own knob-vs-track contrast), and a BAR/RING seen directly
// against black (selection bar, focus ring, Now card Complete ring, segmented marker).
// Every swatch must clear both floors in both uses, or a chosen accent could ship an
// unreadable primary button / an invisible focus ring.
rows.push(["", "", ""]);
rows.push(["-- accent uses --", "", ""]);
const white = { name: "white", hex: null };
const accentSwatches = [white, ...palette.map((p) => ({ name: p.name.replace(/^palette\./, ""), hex: p.hex }))];
for (const accent of accentSwatches) {
  const [r, g, b] = accent.hex ? rgbOf({ kind: "hex", hex: accent.hex }) : [240, 240, 240]; // textPrimary ~0.94 alpha
  const barRingRatio = contrastVsBlack(r, g, b);
  if (barRingRatio < 3) { failed++; rows.push([`accent.${accent.name}.bar`, barRingRatio.toFixed(2), "FAIL: < 3 (selection bar / focus ring / Complete ring vs black)"]); }
  else rows.push([`accent.${accent.name}.bar`, barRingRatio.toFixed(2), "PASS >= 3 (selection bar / focus ring / Complete ring vs black)"]);

  // Label-on-fill: Accent.onFill picks whichever of black/white reads better — the floor
  // is on the WINNER of that choice, so this fails only if a swatch is unreadable both ways.
  const fillLum = luminance(r, g, b);
  const ratioBlackLabel = (fillLum + 0.05) / 0.05;
  const ratioWhiteLabel = 1.05 / (fillLum + 0.05);
  const bestLabelRatio = Math.max(ratioBlackLabel, ratioWhiteLabel);
  if (bestLabelRatio < 4.5) { failed++; rows.push([`accent.${accent.name}.fill`, bestLabelRatio.toFixed(2), "FAIL: < 4.5 (primary button / toggle fill vs its label)"]); }
  else rows.push([`accent.${accent.name}.fill`, bestLabelRatio.toFixed(2), `PASS >= 4.5 (primary button / toggle fill, label=${fillLum > 0.5 ? "black" : "white"})`]);
}

const w = Math.max(...rows.map((r) => r[0].length)) + 2;
for (const [name, ratio, verdict] of rows) {
  console.log(ratio ? `${name.padEnd(w)} ${ratio.padStart(6)}:1  ${verdict}` : name);
}

if (tokens.length === 0) {
  console.error("FAIL: no tokens parsed from Tokens.swift/KColorSwatchPicker.swift — regex out of sync with source");
  process.exit(1);
}
if (palette.length === 0) {
  console.error("FAIL: no palette swatches parsed from KColorSwatchPicker.swift — regex out of sync with source");
  process.exit(1);
}
if (failed > 0) {
  console.error(`FAIL: ${failed} token(s) below their required contrast floor`);
  process.exit(1);
}
console.log("CONTRAST OK");
