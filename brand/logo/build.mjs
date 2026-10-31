// Jotto Live Dot logo: a drawn wordmark and the icons cut from it.
//
//   node brand/logo/build.mjs   -> brand/logo/out/*.svg
//
// The wordmark is built from one stroke weight and one circle. Units: x-height
// 100 (y 70 -> 170), ascender 30, descender 222. The live dot replaces the first
// "o" and is drawn 2 units smaller than the written "o", because a filled disc
// reads larger than a ring of the same size.
//
// Round 5: the shared bar is balanced. Each end now overhangs its stem by the
// same 30 units, so the bar's right end lands exactly on the second t's tail,
// and its left end mirrors the first t's tail.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "out");
mkdirSync(OUT, { recursive: true });

export const ORANGE = "#FF4F00";
export const INK = "#0A0A0A";
export const PAPER = "#FFFFFF";

const S = 20; // stroke
const OVERSHOOT = 2;
const TAIL = 40; // how far a t's tail runs past its stem

// Where each glyph sits. r4 is last round's short bar, kept for comparison.
const LAYOUTS = {
  r4: { j: 56, dot: 138, t1: 234, t2: 300, barL: 208, barR: 324, o: 410 },
  r5: { j: 56, dot: 138, t1: 246, t2: 312, barL: 246 - TAIL, barR: 312 + TAIL, o: 422 },
  // Round 6: the left overhang is shortened (12) or removed (0). The right end
  // still lands on the second t's tail, and the t's close up toward the dot.
  short: { j: 56, dot: 138, t1: 230, t2: 296, barL: 230 - 10 - 12, barR: 296 + TAIL, o: 406 },
  flush: { j: 56, dot: 138, t1: 222, t2: 288, barL: 222 - 10, barR: 288 + TAIL, o: 398 },
};

function parts(L, { s = S, ink = INK, dot = ORANGE, ligature = true } = {}) {
  const hookY = 222 - s / 2;
  const tailY = 170 + OVERSHOOT - s / 2;
  const barY = 70 + s / 2;
  const stroke = (d) => `<path d="${d}" stroke="${ink}" stroke-width="${s}" stroke-linecap="butt" fill="none"/>`;
  const t = (x) => stroke(`M${x} 30 V${tailY - 30} A30 30 0 0 0 ${x + 30} ${tailY} H${x + TAIL}`);
  const mid = (L.t1 + L.t2) / 2;
  return {
    j: stroke(`M${L.j} 70 V${hookY - 30} A30 30 0 0 1 ${L.j - 30} ${hookY} H${L.j - TAIL}`),
    tittle: `<circle cx="${L.j}" cy="36" r="${s / 2 + 2}" fill="${ink}"/>`,
    dot: `<circle cx="${L.dot}" cy="120" r="${52 + OVERSHOOT - 4}" fill="${dot}"/>`,
    t1: t(L.t1),
    t2: t(L.t2),
    bar: ligature ? stroke(`M${L.barL} ${barY} H${L.barR}`) : stroke(`M${L.barL} ${barY} H${mid - 8}`) + stroke(`M${mid + 8} ${barY} H${L.barR}`),
    o: `<circle cx="${L.o}" cy="120" r="${52 - s / 2}" stroke="${ink}" stroke-width="${s}" fill="none"/>`,
  };
}

const all = (p) => [p.j, p.tittle, p.dot, p.t1, p.t2, p.bar, p.o].join("");

const svg = (viewBox, body, w, h) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox}" width="${w}" height="${h}" fill="none">${body}</svg>`;

export function wordmark(layout = "r5", options = {}) {
  const L = LAYOUTS[layout];
  const right = L.o + 52 + 24;
  const left = L.j - TAIL - 24;
  const box = [left, -6, right - left, 256];
  const bg = options.background ? `<rect x="${box[0]}" y="${box[1]}" width="${box[2]}" height="${box[3]}" rx="28" fill="${options.background}"/>` : "";
  return svg(box.join(" "), bg + all(parts(L, options)), box[2], box[3]);
}

function construction() {
  const L = LAYOUTS.r5;
  const rule = (y) => `<line x1="-70" y1="${y}" x2="${L.o + 70}" y2="${y}"/>`;
  const label = (y, text) => `<text x="-70" y="${y - 4}">${text}</text>`;
  const tailEnd2 = L.t2 + TAIL;
  const tailEnd1 = L.t1 + TAIL;
  return svg(
    `-74 -10 ${L.o + 150} 262`,
    [
      `<g stroke="#D9D9D6" stroke-width="0.6">${[30, 70, 170, 222].map(rule).join("")}</g>`,
      `<g stroke="#B5B5B0" stroke-width="0.6" stroke-dasharray="2 2" fill="none">`,
      `<circle cx="${L.dot}" cy="120" r="52"/><circle cx="${L.o}" cy="120" r="52"/>`,
      `<line x1="${L.dot}" y1="44" x2="${L.dot}" y2="198"/><line x1="${L.o}" y1="44" x2="${L.o}" y2="198"/>`,
      `</g>`,
      `<g stroke="${ORANGE}" stroke-width="0.6" stroke-dasharray="2 2">`,
      `<line x1="${L.barL}" y1="8" x2="${L.barL}" y2="196"/><line x1="${L.barR}" y1="8" x2="${L.barR}" y2="196"/><line x1="${tailEnd1}" y1="150" x2="${tailEnd1}" y2="196"/>`,
      `</g>`,
      `<g fill="#9A9A96" font-family="Geist Mono, monospace" font-size="6.5" letter-spacing="0.4">`,
      label(30, "ASCENDER"),
      label(70, "X-HEIGHT"),
      label(170, "BASELINE"),
      label(222, "DESCENDER"),
      `<text x="${L.dot - 20}" y="40">DOT ⌀ 100</text><text x="${L.o - 18}" y="40">O ⌀ 104</text>`,
      `</g>`,
      `<g fill="${ORANGE}" font-family="Geist Mono, monospace" font-size="6.5" letter-spacing="0.4">`,
      `<text x="${L.barL}" y="4">BAR ENDS ON THE TAILS</text>`,
      `<text x="${L.barL + 9}" y="64">30</text><text x="${L.t2 + 19}" y="64">30</text>`,
      `<text x="${tailEnd1 + 4}" y="206">TAIL</text><text x="${L.barR + 4}" y="206">TAIL</text><text x="${L.barL - 4}" y="206" text-anchor="end">MIRROR</text>`,
      `</g>`,
      all(parts(L)),
    ].join(""),
    (L.o + 150) * 2,
    524,
  );
}

// Upper case, for the case question: cap height 140 (30 -> 170).
function capitals() {
  const s = S;
  const stroke = (d) => `<path d="${d}" stroke="${INK}" stroke-width="${s}" stroke-linecap="butt" fill="none"/>`;
  const body = [
    stroke(`M70 30 V130 A30 30 0 0 1 40 160 H24`),
    `<circle cx="174" cy="100" r="70" fill="${ORANGE}"/>`,
    stroke(`M266 40 H446`),
    stroke(`M311 40 V170`),
    stroke(`M401 40 V170`),
    `<circle cx="540" cy="100" r="${72 - s / 2}" stroke="${INK}" stroke-width="${s}" fill="none"/>`,
  ].join("");
  return svg("0 -6 636 212", body, 636, 212);
}

// Icons are cut from the wordmark itself, so they carry its letterforms.
// iOS tile 120 with radius 27 (a stand-in for the squircle). Watch is a circle.
function icon(kind, { round = false } = {}) {
  const L = LAYOUTS.r5;
  const shape = round ? `<circle cx="60" cy="60" r="60"/>` : `<rect width="120" height="120" rx="27"/>`;
  const id = `clip-${kind}${round ? "-w" : ""}`;
  const clip = `<clipPath id="${id}">${shape}</clipPath>`;
  const ground = (fill) => shape.replace("/>", ` fill="${fill}"/>`);
  const place = (inner, k, cx, cy, at = [60, 60]) =>
    `<g clip-path="url(#${id})"><g transform="translate(${at[0] - cx * k} ${at[1] - cy * k}) scale(${k})">${inner}</g></g>`;
  const w = round ? 0.88 : 1;
  const light = parts(L, { ink: PAPER });
  const onOrange = parts(L, { ink: INK, dot: PAPER });
  const body = {
    // "j" and the live dot: the first two letters, as drawn in the wordmark.
    jdot: ground(INK) + place(light.j + light.tittle + light.dot, 0.43 * w, 102, 123, [59, 60]),
    // The same pair on the brand orange, with the dot knocked out to white.
    "jdot-orange": ground(ORANGE) + place(onOrange.j + onOrange.tittle + onOrange.dot, 0.43 * w, 102, 123, [59, 60]),
    // Dot, then the shared-bar t's: sound, then text.
    dottt: ground(INK) + place(light.dot + light.t1 + light.t2 + light.bar, 0.34 * w, (88 + L.barR) / 2, 101, [60, 61]),
    "dottt-orange": ground(ORANGE) + place(onOrange.dot + onOrange.t1 + onOrange.t2 + onOrange.bar, 0.34 * w, (88 + L.barR) / 2, 101, [60, 61]),
  }[kind];
  return svg("0 0 120 120", `<defs>${clip}</defs>${body}`, 120, 120);
}

// Sound to Line, drawn with the wordmark's own dot and bar: a solid o, then a
// bar a little shorter than the dot is wide. Units are the wordmark's.
function soundLine({ round = false, length = 80, lift = 0, weight = S, ground = INK, dot = ORANGE, bar = PAPER } = {}) {
  const k = 0.46 * (round ? 0.88 : 1);
  const gap = 18;
  const width = 100 + gap + length;
  const shape = round ? `<circle cx="60" cy="60" r="60" fill="${ground}"/>` : `<rect width="120" height="120" rx="27" fill="${ground}"/>`;
  // Centre on the bounding box, nudged right 3 units: the dot carries more weight.
  const x0 = 60 - (width * k) / 2 + 3 * k + 50 * k;
  const body = [
    shape,
    `<g transform="translate(${x0} 60) scale(${k})">`,
    `<circle cx="0" cy="0" r="50" fill="${dot}"/>`,
    `<path d="M${50 + gap} ${lift} H${50 + gap + length}" stroke="${bar}" stroke-width="${weight}" stroke-linecap="butt"/>`,
    `</g>`,
  ].join("");
  return svg("0 0 120 120", body, 120, 120);
}

const files = {
  "construction.svg": construction(),
  "wordmark.svg": wordmark("r5"),
  "wordmark-r4.svg": wordmark("r4"),
  "wordmark-dark.svg": wordmark("r5", { ink: PAPER, background: INK }),
  "wordmark-orange.svg": wordmark("r5", { ink: INK, dot: PAPER, background: ORANGE }),
  "wordmark-mono.svg": wordmark("r5", { dot: INK }),
  "wordmark-caps.svg": capitals(),
  "wordmark-short.svg": wordmark("short"),
  "wordmark-flush.svg": wordmark("flush"),
};
const SOUND_LINE = {
  sl: {},
  "sl-short": { length: 60 },
  "sl-heavy": { weight: 30, length: 72 },
  "sl-orange": { ground: ORANGE, dot: PAPER, bar: INK },
  // Round 7: D on orange, with the bar pushed heavier (1.5x to 3x the wordmark stroke).
  ...Object.fromEntries([30, 40, 50, 60].map((weight) => [`sl-orange-${weight}`, { ground: ORANGE, dot: PAPER, bar: INK, weight, length: 72 }])),
};
for (const [name, options] of Object.entries(SOUND_LINE)) {
  files[`icon-${name}.svg`] = soundLine(options);
  files[`icon-${name}-watch.svg`] = soundLine({ ...options, round: true });
}
for (const kind of ["jdot", "jdot-orange", "dottt", "dottt-orange"]) {
  files[`icon-${kind}.svg`] = icon(kind);
  files[`icon-${kind}-watch.svg`] = icon(kind, { round: true });
}
for (const [name, text] of Object.entries(files)) writeFileSync(join(OUT, name), text);
console.log(`wrote ${Object.keys(files).length} files to ${OUT}`);
