// Builds the drawn objects for the Jotto project page (brand/page/index.html) with the anatomy kit:
// an Apple Watch, the watch on its charger, an iPhone, and four generic AI recorders with chargers.
// Every part records its true shape, the painter's order is settled from the geometry, and
//   node brand/page/build.mjs --audit
// proves it (clearance, terminals, supports, depth order …). Writes art.js, iso.css and verify.html.
import { writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const KIT = join(homedir(), ".claude/skills/anatomy/kit");
const k = await import(join(KIT, "iso-kit.mjs"));
const G = await import(join(KIT, "lathe.mjs"));
const A = await import(join(KIT, "audit.mjs"));
const { tubePieces, tubeSvg } = await import(join(KIT, "tube.mjs"));

const HERE = dirname(fileURLToPath(import.meta.url));
const AUDIT = process.argv.includes("--audit");
const AZ = 45, EL = 42, M = 2.4; // world units per millimetre
const mm = (v) => v * M;
const plan = (x, y, w, d, r) => ({ x: mm(x), y: mm(y), w: mm(w), d: mm(d), r: mm(r) });
const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const UP = [0, 0, 1];
let UID = 0;
const zFrame = (x, y, z = 0) => G.frameOf([x, y, z], UP, [1, 0, 0], [0, 1, 0]);

// One camera for every object, so they share a scale on the page.
function camera(points, pad = 24, azimuth = AZ, elevation = EL) {
  const P0 = { origin: [0, 0], scale: 1, azimuth, elevation };
  const flat = points.map((p) => k.iso(p, P0));
  const xs = flat.map((p) => p[0]), ys = flat.map((p) => p[1]);
  const left = Math.min(...xs) - pad, top = Math.min(...ys) - pad;
  return { P: { ...P0, origin: [-left, -top] }, w: Math.ceil(Math.max(...xs) + pad - left), h: Math.ceil(Math.max(...ys) + pad - top) };
}
// Affine map from a top face's local (u right = +x, v down = +y) to the viewBox, for HTML laid on a screen.
function faceMatrix(x, y, z, P) {
  const { sinA, cosA, sinE, k: kk } = k.cameraOf(P);
  const [e, f] = k.iso([x, y, z], P);
  return [sinA * kk, cosA * sinE * kk, -cosA * kk, sinA * sinE * kk, e, f].map((v) => +v.toFixed(4));
}

// A figure: a recorder plus drawing helpers that record each part's true shape as they draw it.
function figure(P, label) {
  const R = A.recorder(P);
  const under = []; // halos, drawn first
  const put = (name, at, svg, shapes = [], o = {}) => R.put({ name, at, svg, shapes, ...o });
  const F = {
    R, P, under,
    halo(p, z, h, blur = 9, g) { under.push({ g, svg: `<path class="iso-halo" d="${k.haloOf(p, z, h, P)}" style="filter:blur(${blur}px)"/>` }); },
    slab(name, p, z, h, style = {}, { steps = 8, bevel = 0, inner = "", extra = "", meta = {}, bias = 0, g } = {}) {
      const shape = R.solid(A.slab(p, z, h, { name, ...meta }, steps));
      return put(name, [p.x + p.w / 2, p.y + p.d / 2, z + h / 2], S(k.slabOf(p, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias, g });
    },
    cyl(name, cx, cy, r, z, h, style = {}, { steps = 40, bevel = 0, inner = "", extra = "", meta = {}, bias = 0, g } = {}) {
      const shape = R.solid(A.cylinder(cx, cy, r, z, h, { name, ...meta }));
      return put(name, [cx, cy, z + h / 2], S(k.cylinder(cx, cy, r, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias, g });
    },
    turned(name, Fr, profile, style = {}, { inner = "", extra = "", meta = {}, bias = 0, g, opts = {} } = {}) {
      const shape = R.solid(A.solid(Fr, profile, { name, ...meta }));
      const mid = (profile[0][0] + profile[profile.length - 1][0]) / 2;
      return put(name, G.add3(Fr.o, G.mul3(Fr.a, mid)), S(G.solidOf(profile, Fr, P, opts), { tone: "mid", ...style, inner }) + extra, [shape], { bias, g });
    },
    // a cable: one route, recorded as tubes, drawn in depth-sortable chunks
    cable(name, points, r, { tone = "mid", bend = mm(6), closed = false, ends = [true, true], maxLength = mm(12), g, meta = {} } = {}) {
      const route = closed ? points : G.fillet(points, bend, 10, { P, tube: r });
      R.route(name, route, r, { closed, ends, limp: true, ...meta });
      tubePieces(route, r, P, { maxLength, closed, spacing: Math.min(1.6, r) }).forEach((piece, index) =>
        put(`${name}:${index}`, piece.mid, tubeSvg(piece, { tone }), [A.tube(piece.points, piece.radii)], { route: name, chunk: index, g }));
      return route;
    },
    out() {
      A.settle(R, P);
      R.items.sort((a, b) => a.key - b.key);
      if (AUDIT) { console.log(`\n=== ${label} ===`); A.auditOrExit(R, P); }
      return { under, items: R.items };
    },
  };
  return F;
}

/* ---------- Apple Watch, lying on its back ---------- */
const CASE = plan(-19, -22.5, 38, 45, 10.5);
const SCREEN = k.insetPlan(CASE, mm(2.5));
function drawWatch(F, lift = 0) {
  const { P } = F, z = (v) => mm(v) + lift, own = { owner: "watch" };
  const top = plan(-11, -92, 22, 61.4, 11), bottom = plan(-11, 30.6, 22, 76.4, 11);
  F.halo(plan(-11, -92, 22, 199, 11), 0, 1, 7); F.halo(CASE, lift, mm(8), 12);
  // a strap: round at its free end, square where it bends into the lug
  const strapRing = (p, freeEnd, inset = 0) => {
    const x0 = p.x + inset, x1 = p.x + p.w - inset, r = (p.w - 2 * inset) / 2, cx = (x0 + x1) / 2, out = [];
    const yFree = freeEnd < 0 ? p.y + p.w / 2 : p.y + p.d - p.w / 2, yRoot = freeEnd < 0 ? p.y + p.d - inset : p.y + inset;
    for (let i = 0; i <= 20; i++) { const a = Math.PI * i / 20; out.push([cx + r * Math.cos(a) * -freeEnd * -1, yFree + freeEnd * r * Math.sin(a)]); }
    out.push([out[out.length - 1][0], yRoot], [out[0][0], yRoot]);
    return out;
  };
  const strap = (name, p, freeEnd, extra = "") => {
    const ring = strapRing(p, freeEnd), shape = F.R.solid(A.extruded(ring, 0, mm(3), { name, ...own, ground: true }));
    const groove = L(k.onTop(strapRing(p, freeEnd, mm(1.4)).slice(0, 21), mm(3), P), { tone: "faint" }) + L(k.onTop([strapRing(p, freeEnd, mm(1.4))[20], [strapRing(p, freeEnd, mm(1.4))[20][0], freeEnd < 0 ? p.y + p.d : p.y]], mm(3), P) + k.onTop([strapRing(p, freeEnd, mm(1.4))[0], [strapRing(p, freeEnd, mm(1.4))[0][0], freeEnd < 0 ? p.y + p.d : p.y]], mm(3), P), { tone: "faint" });
    F.R.put({ name, at: [p.x + p.w / 2, p.y + p.d / 2, mm(1.5)], svg: S(k.extrude(ring, 0, mm(3), P, { bevel: 0.6 }), { tone: "mid" }) + groove + extra, shapes: [shape] });
  };
  // straps lie on the table; the far one carries the pin, the near one the holes
  strap("watch.strap.far", top, -1);
  F.cyl("watch.strap.pin", 0, mm(-82), mm(2.4), mm(3), mm(2.2), {}, { bevel: 0.4, steps: 28, meta: own, extra: L(k.ring(0, mm(-82), mm(1.2), mm(5.2), P, 20), { tone: "lo" }) });
  strap("watch.strap.near", bottom, 1, Array.from({ length: 8 }, (_, i) => { const y = mm(52 + i * 6.5), id = `jh${UID++}`, top = k.ring(0, y, mm(1.3), mm(3), P, 24); return `<clipPath id="${id}"><path d="${top}"/></clipPath><path class="jt-hole" d="${top}"/><path class="jt-floor" clip-path="url(#${id})" d="${k.ring(0, y, mm(1.3), 0, P, 24)}"/>` + L(top, { tone: "lo" }); }).join(""));
  // band connectors: the strap bends up in a quarter curve into the slot in the case side, built as short segments
  for (const [name, y0, dir] of [["far", -22.6, -1], ["near", 22.6, 1]]) {
    const Fr = G.frameOf([mm(-11), mm(y0), 0], [1, 0, 0], [0, dir, 0], UP);
    const R0 = mm(8), T = mm(3), top = z(7.6) - T / 2; // bend radius on the centreline, strap thickness
    const N = 6, pts = (t, off) => { const a = (t * Math.PI) / 2, cu = T / 2 + (R0 - T / 2) * (1 - Math.sin(a)), cv = T / 2 + (top - T / 2) * (1 - Math.cos(a)); const nu = (top - T / 2) * Math.sin(a), nv = R0 * Math.cos(a), l = Math.hypot(nu, nv); return [cu + off * nu / l, cv + off * nv / l]; };
    for (let i = 0; i < N; i++) {
      const t0 = i / N, t1 = (i + 1) / N;
      let quad = [pts(t0, -T / 2), pts(t1, -T / 2), pts(t1, T / 2), pts(t0, T / 2)];
      const area = quad.reduce((s2, [x1, y1], j) => { const [x2, y2] = quad[(j + 1) % 4]; return s2 + x1 * y2 - x2 * y1; }, 0);
      if ((area < 0) !== (dir < 0)) quad = quad.reverse();
      const nm = `watch.lug.${name}.${i}`;
      const shape = F.R.solid(A.prism(Fr, quad, 0, mm(22), { name: nm, ...own, ground: i === 0 }));
      const mid = pts((t0 + t1) / 2, 0);
      F.R.put({ name: nm, at: [mm(0), mm(y0) + dir * mid[0], mid[1]], svg: S(G.prismOf(Fr, quad, 0, mm(22), P), { tone: "mid", crease: "faint" }), shapes: [shape] });
    }
  }
  // sensor back, case, crown, side button
  F.cyl("watch.back", 0, 0, mm(15), lift, mm(1.6), { tone: "lo" }, { steps: 64, meta: { ...own, ground: !lift } });
  F.slab("watch.case", CASE, z(1.6), mm(9.6), { crease: "lo" }, { steps: 12, bevel: 1, meta: own, inner: L(k.sideSeam(CASE, z(3.4), P, 12), { tone: "faint" }),
    extra: D([k.iso([mm(19), mm(-1.5), z(7)], P)], { size: 0.7, tone: "mid" }) });
  const C = G.frameOf([mm(19), mm(-8.5), z(7)], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  F.turned("watch.crown.boss", C, [[0, mm(2.6)], [mm(1.1), mm(2.6)]], { tone: "lo" }, { meta: own });
  F.turned("watch.crown", C, [[mm(1.1), mm(3.7)], [mm(4.4), mm(3.7)]], {}, { meta: own,
    extra: k.fadedSvg(G.ribsOf(C, mm(1.1), mm(4.4), mm(3.7), 54, P, { fade: [0.05, 0.5], seams: true }), { tone: "lo" }) + L(G.circleOf(C, mm(4.4), mm(2.4), P), { tone: "faint" }) });
  F.slab("watch.button", plan(19, 3, 1.2, 13, 0.6), z(4.2), mm(4.4), {}, { steps: 4, bevel: 0.3, meta: own });
  // cover glass and the black display under it
  const glass = k.insetPlan(CASE, mm(0.5));
  F.slab("watch.glass", glass, z(11.2), mm(1.2), { tone: "hi", crease: "faint" }, { steps: 12, bevel: 1.4, meta: own,
    extra: `<path class="jt-black" d="${k.planOutline(k.insetPlan(CASE, mm(1.6)), z(12.4), P, 12)}"/>` });
  return { m: faceMatrix(SCREEN.x, SCREEN.y, z(12.4), P), w: SCREEN.w, h: SCREEN.d, r: SCREEN.r };
}
// The watch turns from lying on the table (iso) to facing the viewer, in frames that share one box,
// with the middle of the case always at the same point of the box.
const WATCH_PTS = [...k.boxCorners(plan(-11, -92, 22, 199, 11), 0, mm(3)), ...k.boxCorners(CASE, 0, mm(13)), [mm(24), mm(-8), mm(7)]];
const POSES = Array.from({ length: 13 }, (_, i) => { const t = i / 12, e = t * t * (3 - 2 * t); return [AZ + 45 * e, EL + 38 * e]; });
function watchBox(poses, extra = []) {
  let l = 0, r = 0, u = 0, d = 0;
  for (const [az, el] of poses) {
    const P0 = { origin: [0, 0], scale: 1, azimuth: az, elevation: el }, o = k.iso([0, 0, mm(6)], P0);
    for (const p of [...WATCH_PTS, ...extra]) { const q = k.iso(p, P0); l = Math.min(l, q[0] - o[0]); r = Math.max(r, q[0] - o[0]); u = Math.min(u, q[1] - o[1]); d = Math.max(d, q[1] - o[1]); }
  }
  const half = Math.ceil(Math.max(-l, r)) + 24, halfH = Math.ceil(Math.max(-u, d)) + 24;
  return { w: half * 2, h: halfH * 2, at: (az, el) => { const P0 = { origin: [0, 0], scale: 1, azimuth: az, elevation: el }, o = k.iso([0, 0, mm(6)], P0); return { ...P0, origin: [half - o[0], halfH - o[1]] }; } };
}
const CHARGER_TAIL = [mm(-150), mm(150), mm(1.4)];
const BOX = watchBox(POSES, [CHARGER_TAIL.map((v, i) => (i < 2 ? v * 0.45 : v))]);
function watchFrame([az, el], i) {
  const P = BOX.at(az, el), F = figure(P, `watch frame ${i}`);
  const screen = drawWatch(F);
  return { ...F.out(), P, vb: [BOX.w, BOX.h], screen, label: "An Apple Watch." };
}
function chargerFigure() {
  // the magnetic charging puck and its cable, in the first pose; the page slides it in under the watch
  const P = BOX.at(...POSES[0]), F = figure(P, "charger");
  F.turned("puck", zFrame(0, 0), [[0, mm(14)], [mm(4.6), mm(14)], [mm(5.5), mm(12.5), 1], [mm(5.5), 0]], { tone: "hi" }, { meta: { ground: true, owner: "puck" } });
  const d = [-Math.SQRT1_2, Math.SQRT1_2];
  const at = (s, zz) => [d[0] * mm(s), d[1] * mm(s), mm(zz)];
  const BF = G.frameOf(at(14.05, 2.4), [d[0], d[1], 0], [d[1], -d[0], 0], UP);
  F.turned("puck.boot", BF, [[0, mm(2.4)], [mm(6), mm(2.4)], [mm(7), mm(2), 1]], { tone: "lo" }, { meta: { owner: "puck" } });
  F.cable("puck.cable", [at(21.05, 2.4), at(25, 2.4), at(31, 1.4), at(60, 1.4), CHARGER_TAIL], mm(1.4), { bend: mm(10), ends: [true, false] });
  return { ...F.out(), P, vb: [BOX.w, BOX.h], label: "A watch charging puck." };
}

/* ---------- iPhone, face up ---------- */
const BODY = plan(-35.3, -73.3, 70.6, 146.6, 11);
const DISPLAY = k.insetPlan(BODY, mm(2.6));
function phoneFigure(az = AZ, el = EL) {
  const { P, w, h } = camera([...k.boxCorners(BODY, 0, mm(8.4)), [mm(37), 0, mm(4)]], 24, az, el);
  const F = figure(P, "iPhone"), zt = mm(8.3), own = { owner: "phone" };
  F.halo(BODY, 0, mm(8), 12);
  F.slab("phone.back", k.insetPlan(BODY, mm(0.5)), 0, mm(0.5), { tone: "lo" }, { steps: 10, meta: { ...own, ground: true } });
  // the frame: seams, antenna breaks, port, speaker and mic holes, screws on the bottom edge
  const port = [];
  for (let i = 0; i <= 32; i++) {
    const a = (i / 32) * Math.PI * 2, c = Math.cos(a), x = Math.sign(c) * Math.min(4.3, Math.abs(c) * 6.9);
    port.push(k.iso([mm(x), mm(73.3), mm(4.1 + 1.5 * Math.sin(a))], P));
  }
  const portD = "M" + port.map((p) => p.map((v) => v.toFixed(1)).join(" ")).join("L") + "Z";
  const holes = [];
  for (let i = 0; i < 6; i++) holes.push(k.iso([mm(-11 - i * 2.2), mm(73.3), mm(4.1)], P), k.iso([mm(11 + i * 2.2), mm(73.3), mm(4.1)], P));
  const ant = [[mm(35.3), mm(-60)], [mm(35.3), mm(58)], [mm(22), mm(73.3)], [mm(-22), mm(73.3)]];
  F.slab("phone.frame", BODY, mm(0.5), mm(7.2), { crease: "lo" }, { steps: 12, bevel: 0.8, meta: own,
    inner: L(k.sideSeam(BODY, mm(1.4), P, 12) + k.sideSeam(BODY, mm(6.8), P, 12), { tone: "faint" }),
    extra: L(ant.map(([x, y]) => k.rise([x, y], mm(1.4), mm(6.8), P)).join(""), { tone: "lo" }) + `<path class="jt-hole" d="${portD}"/>` + L(portD, { tone: "lo" })
      + D(holes, { size: 0.55, tone: "mid" }) + D([k.iso([mm(-7), mm(73.3), mm(4.1)], P), k.iso([mm(7), mm(73.3), mm(4.1)], P)], { size: 0.45, tone: "lo" }) });
  F.slab("phone.button", plan(35.3, -32, 0.8, 17, 0.4), mm(2.6), mm(3), {}, { steps: 4, bevel: 0.3, meta: own });
  F.slab("phone.glass", k.insetPlan(BODY, mm(0.35)), mm(7.7), mm(0.6), { tone: "hi", crease: "faint" }, { steps: 12, bevel: 1.2, meta: own,
    extra: `<path class="jt-black" d="${k.planOutline(k.insetPlan(BODY, mm(1.3)), zt, P, 12)}"/>` });
  return { ...F.out(), P, vb: [w, h], screen: { m: faceMatrix(DISPLAY.x, DISPLAY.y, zt, P), w: DISPLAY.w, h: DISPLAY.d, r: DISPLAY.r }, label: "An iPhone lying face up." };
}

/* ---------- Four AI recorders and the one charging hub they all need ---------- */
const U = [Math.SQRT1_2, -Math.SQRT1_2], V = [Math.SQRT1_2, Math.SQRT1_2]; // along the row on screen, toward the viewer
const onRow = (s, d, z = 0) => [mm(s) * U[0] + mm(d) * V[0], mm(s) * U[1] + mm(d) * V[1], z];
function rring(c, w, d, r, steps = 6) {
  // a rounded rectangle turned to the row: w along U, d along V
  const out = [], hw = w / 2 - r, hd = d / 2 - r;
  for (const [sx, sd, a0] of [[1, -1, -Math.PI / 2], [1, 1, 0], [-1, 1, Math.PI / 2], [-1, -1, Math.PI]])
    for (let i = 0; i <= steps; i++) { const a = a0 + (Math.PI / 2) * (i / steps), u = sx * hw + r * Math.cos(a), v = sd * hd + r * Math.sin(a); out.push([c[0] + u * U[0] + v * V[0], c[1] + u * U[1] + v * V[1]]); }
  return out;
}
function relief(F, g, n, at, dir, r) {
  // a tapered strain relief where the cable leaves its plug
  const Fr = G.frameAlong(at, dir);
  F.turned(`${n}.relief`, Fr, [[0, r * 1.75], [mm(1.5), r * 1.7], [mm(3.4), r * 1.4, 1], [mm(5), r * 1.12]], { tone: "lo" }, { g, meta: { owner: n } });
  return G.add3(at, G.mul3(dir, mm(5)));
}
function boot(F, g, n, x, y, z0, dir = [0, 1]) {
  // a USB-C plug boot pushed into the gadget's edge at (x, y), pointing along dir; a seam round it, and its strain relief
  const [dx, dy] = dir, L8 = 8, W6 = 6;
  const p = dx ? plan(x / M + (dx < 0 ? -L8 : 0), y / M - W6 / 2, L8, W6, 1.6) : plan(x / M - W6 / 2, y / M + (dy < 0 ? -L8 : 0), W6, L8, 1.6);
  F.slab(`${n}.boot`, p, z0, mm(4.6), { tone: "lo" }, { steps: 4, bevel: 0.4, g, meta: { owner: n, ground: z0 === 0 }, inner: L(k.sideSeam(p, z0 + mm(2.3), F.P, 4), { tone: "faint" }) });
  return { tip: relief(F, g, n, [x + dx * mm(L8), y + dy * mm(L8), z0 + mm(2.3)], [dx, dy, 0], mm(1.3)), dir };
}
const GADGETS = [
  function pendant(F, g, cx, cy) {
    const { P } = F, own = { owner: "pendant" };
    F.halo(plan(cx / M - 16, cy / M - 16, 32, 32, 16), 0, mm(8), 8, g);
    const tabY = cy - mm(18.5);
    F.slab("pendant.tab", plan(cx / M - 3, tabY / M - 2, 6, 4, 1), 0, mm(3), { tone: "lo" }, { steps: 3, bevel: 0.3, g, meta: { ...own, ground: true } });
    const loop = [[cx - mm(3), tabY, mm(1.5)], [cx - mm(6), tabY, mm(1.5)]];
    for (let i = 0; i <= 40; i++) { const t = (110 + 320 * i / 40) * Math.PI / 180; loop.push([cx + mm(24) * Math.cos(t), tabY - mm(26) + mm(24) * Math.sin(t), mm(0.9)]); }
    loop.push([cx + mm(6), tabY, mm(1.5)], [cx + mm(3), tabY, mm(1.5)]);
    F.cable("pendant.lanyard", loop, mm(0.9), { g, bend: mm(4), maxLength: mm(14) });
    const Fz = zFrame(cx, cy);
    F.turned("pendant.body", Fz, [[0, mm(16)], [mm(4.4), mm(16)], [mm(5.8), mm(15.2), 1], [mm(7), mm(12.6), 1], [mm(7.8), mm(7), 1], [mm(8), 0]], { tone: "hi" },
      { g, meta: { ...own, ground: true }, inner: L(G.arcOf(Fz, mm(4.4), mm(16), P), { tone: "faint" }), extra: L(G.circleOf(Fz, mm(7.45), mm(9.5), P), { tone: "faint" }) + D([k.iso([cx + mm(5.5), cy - mm(5.5), mm(7.6)], P)], { size: 0.8, tone: "hi" }) });
    F.turned("pendant.lens", zFrame(cx, cy, mm(7.6)), [[0, mm(3.4)], [mm(1), mm(3.4)]], {}, { g, meta: own, extra: `<path class="jt-black" d="${G.circleOf(zFrame(cx, cy, mm(8.6)), 0, mm(1.8), P)}"/>` });
    return boot(F, g, "pendant", cx + mm(15.9), cy, mm(0.7), [1, 0]);
  },
  function clip(F, g, cx, cy) {
    const { P } = F, own = { owner: "clip" }, body = plan(cx / M - 12, cy / M - 26, 24, 52, 12);
    F.halo(body, 0, mm(10), 8, g);
    F.slab("clip.body", body, 0, mm(9), { crease: "lo" }, { steps: 12, bevel: 1, g, meta: { ...own, ground: true }, inner: L(k.sideSeam(body, mm(4.5), P, 12), { tone: "faint" }),
      extra: D(k.dotGrid(cx - mm(4.5), cy + mm(13), 4, 3, mm(3), mm(9), P), { size: 0.55, tone: "mid" }) });
    const H = G.frameOf([cx - mm(6), cy - mm(20), mm(10.6)], [1, 0, 0], [0, 1, 0], UP);
    F.turned("clip.hinge", H, [[0, mm(1.6)], [mm(12), mm(1.6)]], { tone: "lo" }, { g, meta: own });
    const c = plan(cx / M - 8, cy / M - 18.4, 16, 30.4, 8);
    F.slab("clip.spring", c, mm(9.8), mm(1.6), { tone: "hi" }, { steps: 10, bevel: 0.6, g, meta: own, extra: L(k.planOutline(k.insetPlan(c, mm(2)), mm(11.4), P, 10), { tone: "faint" }) });
    F.cyl("clip.key", cx + mm(6.5), cy + mm(19), mm(1.6), mm(9), mm(0.6), { tone: "hi" }, { steps: 20, g, meta: own });
    return boot(F, g, "clip", cx, cy - mm(26), mm(2.2), [0, -1]);
  },
  function pin(F, g, cx, cy) {
    const { P } = F, own = { owner: "pin" }, body = plan(cx / M - 21, cy / M - 21, 42, 42, 10);
    F.halo(body, 0, mm(12), 8, g);
    F.slab("pin.battery", k.insetPlan(body, mm(1.5)), 0, mm(3.4), { tone: "lo" }, { steps: 10, bevel: 0.5, g, meta: { ...own, ground: true } });
    F.slab("pin.body", body, mm(3.4), mm(8.4), { crease: "lo" }, { steps: 12, bevel: 1, g, meta: own, inner: L(k.sideSeam(body, mm(5), P, 12), { tone: "faint" }),
      extra: L(k.planOutline(k.insetPlan(body, mm(4)), mm(11.8), P, 12), { tone: "faint" }) + D([k.iso([cx + mm(12), cy - mm(9), mm(11.8)], P)], { size: 0.7, tone: "hi" }) + D(k.dotGrid(cx - mm(9), cy + mm(10), 7, 3, mm(3), mm(11.8), P), { size: 0.55, tone: "mid" }) });
    const lx = cx - mm(7), ly = cy - mm(7);
    F.cyl("pin.lens", lx, ly, mm(6.2), mm(11.8), mm(1.6), { tone: "hi" }, { steps: 44, bevel: 0.6, g, meta: own,
      extra: `<path class="jt-black" d="${k.ring(lx, ly, mm(3.4), mm(13.4), P, 32)}"/>` + L(k.ring(lx, ly, mm(4.8), mm(13.4), P, 32), { tone: "lo" }) });
    F.cyl("pin.sensor", cx + mm(8), cy - mm(9), mm(1.8), mm(11.8), mm(0.6), { tone: "hi" }, { steps: 20, g, meta: own });
    return boot(F, g, "pin", cx - mm(21), cy, 0, [-1, 0]);
  },
  function card(F, g, cx, cy) {
    const { P } = F, own = { owner: "card" }, body = plan(cx / M - 27, cy / M - 43, 54, 86, 5);
    F.halo(body, 0, mm(3), 8, g);
    const rules = Array.from({ length: 5 }, (_, i) => L(k.lineOnTop([cx - mm(14), cy - mm(36) + mm(i * 1.6)], [cx + mm(14), cy - mm(36) + mm(i * 1.6)], mm(3.4), P), { tone: "faint", free: true })).join("");
    F.slab("card.body", body, 0, mm(3.4), { crease: "lo" }, { steps: 8, bevel: 0.8, g, meta: { ...own, ground: true },
      extra: L(G.circleOf(zFrame(cx, cy - mm(6), mm(3.4)), 0, mm(22), P) + G.circleOf(zFrame(cx, cy - mm(6), mm(3.4)), 0, mm(19.5), P) + k.planOutline(k.insetPlan(body, mm(2.6)), mm(3.4), P, 8), { tone: "faint" }) + rules + D(k.dotGrid(cx + mm(9), cy + mm(26), 3, 1, mm(2.4), mm(3.4), P), { size: 0.55, tone: "mid" }) + D([k.iso([cx + mm(18), cy + mm(36), mm(3.4)], P)], { size: 0.8, tone: "hi" }) });
    F.cyl("card.key", cx, cy + mm(26), mm(5), mm(3.4), mm(0.8), { tone: "hi" }, { steps: 36, bevel: 0.4, g, meta: own, extra: L(k.ring(cx, cy + mm(26), mm(3), mm(4.2), P, 28), { tone: "faint" }) });
    return boot(F, g, "card", cx, cy + mm(43), 0, [0, 1]);
  },
];
const NAMES = ["pendant", "clip", "pin", "card"];
// where each gadget sits: along the row (s) and toward the viewer (d), in mm; the hub sits in front
// A 2 × 2 of gadgets round one charging hub; (s, d) in mm: s along the row on screen, d toward the viewer.
// GADGETS order: pendant, clip, pin, card → top-left, bottom-left, bottom-right, top-right.
const SPOTS = [[-150, -66], [-160, 40], [150, 34], [172, -82]];
const HUB = { s: 0, d: -16, size: 40, h: 18 };
// for each gadget: which hub face (-1 left, +1 right), the d of its port on that face, the s of its cable's crossing leg
const PORTS = [[-1, -24, -72], [-1, -8, -62], [1, -8, 62], [1, -24, 72]];
const sdOf = ([x, y]) => [(x * U[0] + y * U[1]) / M, (x * V[0] + y * V[1]) / M];
function rringV(c, len, wid, r, steps = 6) {
  // a rounded rectangle with its length along V (toward the viewer) and its width along U
  const out = [], hl = len / 2 - r, hw = wid / 2 - r;
  for (const [su, sv, a0] of [[1, -1, -Math.PI / 2], [1, 1, 0], [-1, 1, Math.PI / 2], [-1, -1, Math.PI]])
    for (let i = 0; i <= steps; i++) { const a = a0 + (Math.PI / 2) * (i / steps), u = su * hw + r * Math.cos(a), v = sv * hl + r * Math.sin(a); out.push([c[0] + u * U[0] + v * V[0], c[1] + u * U[1] + v * V[1]]); }
  return out;
}
function hub(F) {
  const g = 4, own = { owner: "hub" }, c = onRow(HUB.s, HUB.d), P = F.P, Z = mm(HUB.h);
  const ring = rringV(c, mm(HUB.size), mm(HUB.size), mm(7), 8);
  F.under.push({ g, svg: `<path class="iso-halo" d="${k.pathOf(ring.map(([x, y]) => k.iso([x, y, 0], P)), true)}" style="filter:blur(9px)"/>` });
  const top = rringV(c, mm(HUB.size - 7), mm(HUB.size - 7), mm(4), 8);
  const leds = [-6, 6].flatMap((ds) => [-6, 6].map((dd) => k.iso(onRow(HUB.s + ds, HUB.d + dd, Z), P)));
  F.R.put({ name: "hub", at: [c[0], c[1], Z / 2], g, shapes: [F.R.solid(A.extruded(ring, 0, Z, { name: "hub", ...own, ground: true }))],
    svg: S(k.extrude(ring, 0, Z, P, { bevel: 1 }), { tone: "mid", crease: "lo", inner: L(k.ringSeam(ring, mm(3.5), P), { tone: "faint" }) })
      + L(k.onTop(top, Z, P, true), { tone: "faint" }) + D(leds, { size: 0.9, tone: "hi" }) });
  // a low plug in a side face for each gadget; the strain relief points away from the hub
  return PORTS.map(([side, d], i) => {
    const face = HUB.s + side * HUB.size / 2, pc = onRow(face + side * 4, d);
    const pring = rringV(pc, mm(7), mm(8), mm(1.6), 3);
    F.R.put({ name: `hub.plug${i}`, at: [pc[0], pc[1], mm(4.6)], g, shapes: [F.R.solid(A.extruded(pring, mm(2.3), mm(4.6), { name: `hub.plug${i}`, ...own, ground: true }))],
      svg: S(k.extrude(pring, mm(2.3), mm(4.6), P, { bevel: 0.4 }), { tone: "lo" }) });
    return relief(F, g, `hub.plug${i}`, onRow(face + side * 8, d, mm(4.6)), [side * U[0], side * U[1], 0], mm(1.3));
  });
}
function gadgetsFigure() {
  const centres3 = SPOTS.map(([s, d]) => onRow(s, d));
  const pts = [];
  centres3.forEach(([x, y]) => pts.push([x - mm(60), y - mm(100), 0], [x + mm(50), y + mm(70), mm(14)], [x + mm(50), y - mm(60), mm(14)], [x - mm(60), y + mm(40), 0]));
  const { P, w, h } = camera(pts, 30);
  const F = figure(P, "gadgets");
  const ends = hub(F);
  centres3.forEach(([cx, cy], g) => {
    const { tip: start, dir } = GADGETS[g](F, g, cx, cy), end = ends[g], [side, dPort] = PORTS[g];
    const out = (dist, z) => [start[0] + dir[0] * mm(dist), start[1] + dir[1] * mm(dist), z];
    const p2 = out(22, mm(1.3)), [s2, d2] = sdOf(p2), [se] = sdOf(end), far = side * Math.max(side * s2, side * (se + side * 22));
    // out of the plug, down to the table, out to the side of the hub, along to its port, in and up into the plug
    const route = [start, out(6, start[2]), p2];
    if (Math.abs(far - s2) > 4) route.push(onRow(far, d2, mm(1.3)));
    if (Math.abs(d2 - dPort) > 4) route.push(onRow(far, dPort, mm(1.3)));
    route.push(onRow(se + side * 5, dPort, end[2]), end);
    F.cable(`${NAMES[g]}.cable`, route, mm(1.3), { g: 4, bend: mm(11) });
  });
  const centres = [...centres3, onRow(HUB.s, HUB.d)].map((c) => k.iso([c[0], c[1], 0], P));
  return { ...F.out(), P, vb: [w, h], centres, label: "Four AI recorders, a pendant, a clip-on, a pin and a card, wired to one charging hub." };
}

/* ---------- Output ---------- */
const svgOf = (fig, body) => k.figureSvg({ width: fig.vb[0], height: fig.vb[1], label: fig.label, body });
function flat(fig) { return { svg: svgOf(fig, fig.under.map((u) => u.svg).join("") + fig.items.map((it) => it.svg).join("")), vb: fig.vb, screen: fig.screen }; }
function grouped(fig) {
  const body = fig.centres.map(([x, y], g) => `<g class="jt-gadget" data-i="${g}" style="transform-origin:${x.toFixed(1)}px ${y.toFixed(1)}px">${fig.under.filter((u) => u.g === g).map((u) => u.svg).join("")}${fig.items.filter((it) => it.g === g).map((it) => it.svg).join("")}</g>`).join("");
  return { svg: svgOf(fig, body), vb: fig.vb };
}
const frames = POSES.map(watchFrame);
const heroWatch = (() => { const { P, w, h } = camera(WATCH_PTS), F = figure(P, "hero watch"), screen = drawWatch(F); return { ...F.out(), P, vb: [w, h], screen, label: "An Apple Watch lying on its back, band laid out." }; })();
const ART = {
  watch: flat(heroWatch),
  frames: { vb: [BOX.w, BOX.h], svgs: frames.map((f) => svgOf(f, f.under.map((u) => u.svg).join("") + f.items.map((it) => it.svg).join(""))), screens: frames.map((f) => f.screen) },
  charger: flat(chargerFigure()),
  phone: flat(phoneFigure(90, 80)),
  gadgets: grouped(gadgetsFigure()),
};
writeFileSync(join(HERE, "iso.css"), `/* The anatomy kit styles (ISO_CSS), copied by build.mjs. */\n${k.ISO_CSS}\n`);
writeFileSync(join(HERE, "art.js"), `// Generated by brand/page/build.mjs; edit there.\nwindow.JOTTO_ART = ${JSON.stringify(ART)};\n`);
// A static sheet of every figure for scripts/lines.mjs and close-ups.
const sheet = Object.entries(ART).filter(([n]) => n !== "frames").map(([n, a]) => `<div class="iso-stage" data-fig="${n}" style="width:${a.vb[0] * 2}px">${a.svg}</div>`).join("");
writeFileSync(join(HERE, "verify.html"), k.pageHtml({ title: "Jotto objects", theme: "light", width: 2800,
  body: `<style>.jt-black{fill:#0a0a0a}.jt-hole{fill:var(--anatomy-shade-0)}.jt-floor{fill:var(--anatomy-paper)}.iso-stage svg{width:100%;height:auto;display:block}</style>${sheet}` }));
console.log("wrote art.js, iso.css, verify.html", Object.fromEntries(Object.entries(ART).map(([n, a]) => [n, a.vb])));
