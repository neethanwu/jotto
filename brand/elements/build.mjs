// Jotto visual elements: the isometric objects from logomark round 2 that were
// kept as illustration (website, empty states, onboarding), repainted in the
// brand orange #FF4F00, plus "Dot and Line", the app icon as an object. Drawn
// with the anatomy kit's camera and solids, with inline fills so every SVG
// stands alone. brand/logomark/ keeps the round 2 originals.
//
//   node brand/elements/build.mjs            -> brand/elements/out/*.svg + sheet.html
//   node brand/elements/build.mjs --dark     -> dark-ground variants as well
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const KIT = join(homedir(), ".claude/skills/anatomy/kit");
const k = await import(join(KIT, "iso-kit.mjs"));
const G = await import(join(KIT, "lathe.mjs"));

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "out");
mkdirSync(OUT, { recursive: true });

const SIZE = 200;

// #FF4F00 on the top face; the sides step darker by how far they face from the light.
const ORANGE = (edge) => ({ top: "#FF4F00", shades: ["#8A2B00", "#B33700", "#D94300", "#F04A00"], edge });

const THEMES = {
  light: {
    ground: "#FFFFFF",
    paper: "#FFFFFF",
    top: "#FFFFFF",
    shades: ["#18181A", "#3C3C40", "#A6A6AA", "#D6D6D8"],
    ink: "#111113",
    crease: "#111113",
    accent: ORANGE("#111113"),
  },
  dark: {
    ground: "#0B0B0C",
    paper: "#0B0B0C",
    top: "#F2F2F0",
    shades: ["#2A2A2D", "#4A4A4E", "#8E8E92", "#BDBDC0"],
    ink: "#0B0B0C",
    crease: "#0B0B0C",
    accent: ORANGE("#0B0B0C"),
  },
};

const EDGE = 2.4;
const CREASE = 1.5;

// One solid, painted fill -> sides -> top -> crease -> outline, like solidSvg,
// but with inline colours so the file stands alone.
function solid(paths, T, { lit = false, crease = true } = {}) {
  const c = lit ? T.accent : T;
  const out = [`<path d="${paths.fill}" fill="${T.paper}"/>`];
  paths.shades.forEach((d, shade) => {
    if (d) out.push(`<path d="${d}" fill="${c.shades[shade]}"${paths.seamless ? ` stroke="${c.shades[shade]}" stroke-width="0.4"` : ""}/>`);
  });
  if (paths.top) out.push(`<path d="${paths.top}" fill="${c.top}"${paths.seamless ? ` stroke="${c.top}" stroke-width="0.4"` : ""}/>`);
  if (crease && paths.crease) out.push(line(paths.crease, lit ? c.edge : T.crease, CREASE));
  out.push(line(paths.outline, lit ? c.edge : T.ink, EDGE));
  return `<g>${out.join("")}</g>`;
}

const line = (d, color, width) =>
  d ? `<path d="${d}" fill="none" stroke="${color}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round"/>` : "";

const fit = (points, azimuth = 45) => k.fitProjection(points, SIZE, SIZE, { pad: 22, azimuth });
const corners = (plan, z0, z1) => k.boxCorners(plan, z0, z1);
const cyl = (cx, cy, r, z0, z1) => [
  [cx - r, cy - r, z0], [cx + r, cy + r, z0], [cx - r, cy + r, z1], [cx + r, cy - r, z1], [cx - r, cy - r, z1], [cx + r, cy + r, z1],
];

// ── The marks ────────────────────────────────────────────────────────────────
// Each is one object whose working is the idea. Few parts, one accent.

const MARKS = [
  {
    id: "01-record-key",
    name: "Record Key",
    idea: "A single key with the record button pressed into it. The iOS tile and the button are the same object.",
    draw(T) {
      const key = { x: -40, y: -40, w: 80, d: 80, r: 20 };
      const P = fit([...corners(key, 0, 16), ...cyl(0, 0, 20, 16, 26)]);
      return [
        solid(k.slabOf(key, 0, 16, P, 10, 1.2), T),
        line(k.ring(0, 0, 25, 16, P, 64), T.ink, CREASE),
        solid(k.cylinder(0, 0, 20, 16, 9, P, 64), T, { lit: true }),
      ];
    },
  },
  {
    id: "02-sound-to-line",
    name: "Sound to Line",
    idea: "Four bars of sound step down until they lie flat as one line: the transcript.",
    draw(T) {
      const bars = [
        { x: -52, h: 30 },
        { x: -38, h: 56 },
        { x: -24, h: 40 },
        { x: -10, h: 18 },
      ];
      const W = 10;
      const lineBar = { x: 4, y: -W / 2, w: 52, d: W, r: 2.5 };
      const plans = bars.map((b) => ({ x: b.x, y: -W / 2, w: W, d: W, r: 2.5 }));
      const P = fit([...plans.flatMap((p, i) => corners(p, 0, bars[i].h)), ...corners(lineBar, 0, 10)], 35);
      return [
        ...plans.map((plan, i) => solid(k.slabOf(plan, 0, bars[i].h, P, 4, 0), T)),
        solid(k.slabOf(lineBar, 0, 10, P, 4, 0), T, { lit: true }),
      ];
    },
  },
  {
    id: "03-wrist",
    name: "Wrist",
    idea: "The watch you already wear, with one live dot on its face. Crown on the side, strap stubs, nothing else.",
    draw(T) {
      const body = { x: -30, y: -36, w: 60, d: 72, r: 18 };
      const strapA = { x: -20, y: -58, w: 40, d: 24, r: 4 };
      const strapB = { x: -20, y: 34, w: 40, d: 24, r: 4 };
      const crownF = G.frameAlong([30, -6, 11], [1, 0, 0]);
      const P = fit([...corners(body, 0, 22), ...corners(strapA, 4, 14), ...corners(strapB, 4, 14), [38, -6, 18]]);
      return [
        solid(k.slabOf(strapA, 4, 10, P, 4, 0), T),
        solid(k.slabOf(body, 0, 22, P, 10, 1.4), T),
        line(k.planOutline(k.insetPlan(body, 7), 22, P, 10), T.ink, CREASE),
        solid(G.disc(0, 7, 6, crownF, P), T),
        solid(k.cylinder(0, 0, 11, 22, 3, P, 48), T, { lit: true }),
        solid(k.slabOf(strapB, 4, 10, P, 4, 0), T),
      ];
    },
  },
  {
    id: "04-jot-pad",
    name: "Jot Pad",
    idea: "A short stack of paper with a puck resting on the top sheet: the note, and the thing that is listening.",
    draw(T) {
      const sheets = [0, 1, 2].map((i) => ({ x: -44 + i * 3, y: -34 - i * 3, w: 80, d: 64, r: 6 }));
      const P = fit([...sheets.flatMap((s, i) => corners(s, i * 7, i * 7 + 6)), ...cyl(14, -18, 13, 20, 32)]);
      const top = sheets[2];
      return [
        ...sheets.map((s, i) => solid(k.slabOf(s, i * 7, 6, P, 6, 0), T)),
        ...[0, 1, 2].map((i) =>
          line(k.lineOnTop([top.x + 10, top.y + 34 + i * 9], [top.x + 10 + [44, 52, 30][i], top.y + 34 + i * 9], 20, P), T.ink, CREASE),
        ),
        solid(k.cylinder(14, -14, 13, 20, 9, P, 48), T, { lit: true }),
      ];
    },
  },
  {
    id: "05-dot-and-line",
    name: "Dot and Line",
    idea: "The app icon as an object: a live puck, then a bar laid flat beside it, the line it becomes.",
    draw(T) {
      const R = 26;
      const bar = { x: 9, y: -10.5, w: 37, d: 21, r: 3 }; // the icon's proportions: gap 18, length 72, weight 40 per 100 of dot
      const P = fit([...cyl(-26, 0, R, 0, 14), ...corners(bar, 0, 14)], 35);
      return [
        solid(k.cylinder(-26, 0, R, 0, 14, P, 64), T, { lit: true }),
        solid(k.slabOf(bar, 0, 14, P, 6, 0.8), T),
      ];
    },
  },
];

// ── Write ────────────────────────────────────────────────────────────────────

const themes = process.argv.includes("--dark") ? ["light", "dark"] : ["light"];
const svgOf = (mark, theme) => {
  const T = THEMES[theme];
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}" role="img" aria-label="Jotto: ${mark.name}">${mark.draw(T).join("")}</svg>`;
};

const cells = [];
for (const mark of MARKS) {
  for (const theme of themes) {
    const svg = svgOf(mark, theme);
    writeFileSync(join(OUT, `${mark.id}${theme === "dark" ? "-dark" : ""}.svg`), svg);
    cells.push(`<figure style="background:${THEMES[theme].ground}"><div>${svg}</div><figcaption>${mark.name}</figcaption></figure>`);
  }
}
writeFileSync(
  join(OUT, "sheet.html"),
  `<!doctype html><meta charset="utf-8"><title>Jotto visual elements</title><style>body{margin:0;padding:40px;font:14px system-ui;background:#eee;display:flex;flex-wrap:wrap;gap:16px}figure{margin:0;width:280px;padding:20px;border-radius:16px}figure div svg{width:240px;height:240px;display:block}figcaption{color:#888;padding-top:8px}</style>${cells.join("")}`,
);
console.log(`wrote ${MARKS.length * themes.length} svgs to ${OUT}`);
