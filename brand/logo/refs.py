"""Jotto wordmark references from real typefaces.

    python3 -I brand/logo/refs.py   -> brand/logo/out/ref-*.svg

Takes the real j, o and t outlines from a font, replaces the first "o" with a
filled live dot the size of the font's own o (2% smaller, as in the drawn
version), and joins the two t crossbars into one shared bar. These are
references for redrawing, not final art.
"""

import os
import sys

from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTCollection, TTFont
from matplotlib.path import Path

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
HOME = os.path.expanduser("~")
ORANGE = "#FF4F00"
INK = "#0A0A0A"

FONTS = {
    "avenir": ("/System/Library/Fonts/Avenir Next.ttc", 2, "Avenir Next Demi Bold"),
    "sfrounded": ("/Library/Fonts/SF-Pro-Rounded-Semibold.otf", None, "SF Pro Rounded Semibold"),
    "satoshi": (f"{HOME}/Library/Fonts/Satoshi-Bold.otf", None, "Satoshi Bold"),
}


def load(path, index):
    return TTCollection(path).fonts[index] if index is not None else TTFont(path)


def outline(font, name):
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    glyph = glyphs[cmap[ord(name)]]
    svg = SVGPathPen(glyphs)
    glyph.draw(svg)
    rec = RecordingPen()
    glyph.draw(rec)
    return svg.getCommands(), rec.value, glyph.width


def mpl_path(recording):
    verts, codes = [], []
    for op, pts in recording:
        if op == "moveTo":
            verts.append(pts[0]); codes.append(Path.MOVETO)
        elif op == "lineTo":
            verts.append(pts[0]); codes.append(Path.LINETO)
        elif op == "qCurveTo":
            # split implied on-curve points
            off = list(pts[:-1]); end = pts[-1]
            for i, c in enumerate(off):
                nxt = end if i == len(off) - 1 else ((c[0] + off[i + 1][0]) / 2, (c[1] + off[i + 1][1]) / 2)
                verts += [c, nxt]; codes += [Path.CURVE3, Path.CURVE3]
        elif op == "curveTo":
            verts += list(pts); codes += [Path.CURVE4] * 3
        elif op in ("closePath", "endPath"):
            verts.append((0, 0)); codes.append(Path.CLOSEPOLY)
    return Path(verts, codes)


def bbox(recording):
    pts = [p for _, ps in recording for p in ps]
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def filled(paths, x, y):
    inside = sum(p.contains_point((x, y)) for p in paths)
    return inside % 2 == 1 or inside > 0


def crossbar(recording, xheight):
    """Left and right ends and the y band of a t's crossbar, found by probing."""
    contours, cur = [], []
    for op, pts in recording:
        cur.append((op, pts))
        if op in ("closePath", "endPath"):
            contours.append(mpl_path(cur)); cur = []
    x0, y0, x1, y1 = bbox(recording)
    probe_x = x1 - (x1 - x0) * 0.08
    ys = [y for y in range(int(xheight * 0.5), int(y1)) if filled(contours, probe_x, y)]
    band = (min(ys), max(ys))
    mid = sum(band) / 2
    xs = [x for x in range(int(x0), int(x1) + 1) if filled(contours, x, mid)]
    return min(xs), max(xs), band


def build(key):
    path, index, label = FONTS[key]
    font = load(path, index)
    xheight = font["OS/2"].sxHeight
    j, jrec, jw = outline(font, "j")
    o, orec, ow = outline(font, "o")
    t, trec, tw = outline(font, "t")
    track = -0.01 * font["head"].unitsPerEm

    ox0, oy0, ox1, oy1 = bbox(orec)
    r = (oy1 - oy0) / 2 * 0.98
    left, right, band = crossbar(trec, xheight)

    x = 0
    parts = [f'<path d="{j}" fill="{INK}" transform="translate({x} 0)"/>']
    jdot = jw + track + kern / 100 * xheight
    x += jdot
    parts.append(f'<circle cx="{x + (ox0 + ox1) / 2}" cy="{(oy0 + oy1) / 2}" r="{r}" fill="{ORANGE}"/>')
    x += ow + track
    t1 = x
    parts.append(f'<path d="{t}" fill="{INK}" transform="translate({x} 0)"/>')
    x += tw + track
    t2 = x
    parts.append(f'<path d="{t}" fill="{INK}" transform="translate({x} 0)"/>')
    # Reach into each crossbar by half its height, so rounded ends are covered too.
    reach = (band[1] - band[0]) / 2 + 4
    parts.append(f'<rect x="{t1 + right - reach}" y="{band[0]}" width="{t2 + left - t1 - right + 2 * reach}" height="{band[1] - band[0]}" fill="{INK}"/>')
    x += tw + track
    parts.append(f'<path d="{o}" fill="{INK}" transform="translate({x} 0)"/>')
    x += ow

    jx0, jy0, _, _ = bbox(jrec)
    _, _, _, ty1 = bbox(trec)
    top = max(ty1, bbox(jrec)[3])
    pad = font["head"].unitsPerEm * 0.06
    vb = (min(0, jx0) - pad, -top - pad, x - min(0, jx0) + 2 * pad, top - jy0 + 2 * pad)
    width = 512
    height = round(width * vb[3] / vb[2])
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(f"{v:.0f}" for v in vb)}" width="{width}" height="{height}">'
        f'<g transform="scale(1 -1)">{"".join(parts)}</g></svg>'
    )
    with open(os.path.join(OUT, f"ref-{key}.svg"), "w") as f:
        f.write(svg)
    print(f"ref-{key}.svg  {label}  dot r={r:.0f}  bar band={band}")


def contours_of(recording):
    out, cur = [], []
    for op, pts in recording:
        cur.append((op, pts))
        if op in ("closePath", "endPath"):
            out.append(mpl_path(cur)); cur = []
    return out


def satoshi(spur=None, tighten=False, ink=INK, dot=ORANGE, background=None, name="satoshi", guides=False, kern=0):
    """The wordmark in Satoshi Bold, with the first t's left spur cut to `spur`
    x-height hundredths (None keeps the font's own). Satoshi's t is a plain
    cross with no tail: the bar overhangs the stem by the same amount each side.
    With `tighten`, everything after the dot closes up by what the spur lost.
    With `guides`, draws the construction drawing over it. `kern` opens the
    j-to-dot gap, in x-height hundredths."""
    path, index, _ = FONTS["satoshi"]
    font = load(path, index)
    xheight = font["OS/2"].sxHeight
    j, jrec, jw = outline(font, "j")
    o, orec, ow = outline(font, "o")
    t, trec, tw = outline(font, "t")
    track = -0.01 * font["head"].unitsPerEm
    # Satoshi's t is a plain cross, so its stem and bar come straight from the outline.
    points = [pt for _, pts in trec for pt in pts]
    left, stem_l, stem_r, right = sorted({x for x, _ in points})
    band = sorted({y for _, y in points})[1:3]
    stem = [stem_l, stem_r]
    native = stem_l - left
    cut = native if spur is None else spur / 100 * xheight
    shift = native - cut if tighten else 0

    ox0, oy0, ox1, oy1 = bbox(orec)
    r = (oy1 - oy0) / 2 * 0.98
    x = 0
    parts = [f'<path d="{j}" fill="{ink}"/>']
    jdot = jw + track + kern / 100 * xheight
    x += jdot
    parts.append(f'<circle cx="{x + (ox0 + ox1) / 2}" cy="{(oy0 + oy1) / 2}" r="{r}" fill="{dot}"/>')
    x += ow + track - shift
    t1 = x
    clip = f'<clipPath id="spur-{name}"><rect x="{t1 + stem_l - cut}" y="-400" width="2000" height="1600"/></clipPath>'
    parts.append(f'<g clip-path="url(#spur-{name})"><path d="{t}" fill="{ink}" transform="translate({t1} 0)"/></g>')
    x += tw + track
    t2 = x
    parts.append(f'<path d="{t}" fill="{ink}" transform="translate({t2} 0)"/>')
    reach = (band[1] - band[0]) / 2
    parts.append(f'<rect x="{t1 + right - reach}" y="{band[0]}" width="{t2 + left - t1 - right + 2 * reach}" height="{band[1] - band[0]}" fill="{ink}"/>')
    x += tw + track
    parts.append(f'<path d="{o}" fill="{ink}" transform="translate({x} 0)"/>')
    x += ow

    jx0, jy0, jx1, jy1 = bbox(jrec)
    top = max(bbox(trec)[3], jy1)
    pad = 120
    vb = [jx0 - pad, -top - pad, x - jx0 + 2 * pad, top - jy0 + 2 * pad]
    over, labels = "", ""
    if guides:
        u = lambda v: f"{v / xheight * 100:.0f}"
        dot_cx = jdot + (ox0 + ox1) / 2
        cy = (oy0 + oy1) / 2
        cut_x = t1 + stem_l - cut
        stem_r = max(stem)
        rules = [(0, "BASELINE"), (xheight, "X-HEIGHT"), (bbox(trec)[3], "t TOP"), (jy1, "ASCENDER"), (jy0, "DESCENDER")]
        L, R = jx0 - 380, x + 80
        line = lambda x1, y1, x2, y2: f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"/>'
        text = lambda tx, ty, body, anchor="start": f'<text x="{tx}" y="{-ty}" text-anchor="{anchor}">{body}</text>'
        over = (
            f'<g stroke="#D9D9D6" stroke-width="3">{"".join(line(L, y, R, y) for y, _ in rules)}</g>'
            f'<g stroke="#B5B5B0" stroke-width="3" stroke-dasharray="10 10" fill="none">'
            f'<circle cx="{dot_cx}" cy="{(oy0 + oy1) / 2}" r="{(oy1 - oy0) / 2}"/>'
            f'{line(dot_cx, oy0 - 70, dot_cx, oy1 + 70)}</g>'
            f'<g stroke="{ORANGE}" stroke-width="3" stroke-dasharray="10 10">'
            f'{line(cut_x, band[0] - 140, cut_x, band[1] + 150)}{line(t1 + stem_l, band[0] - 140, t1 + stem_l, band[1] + 150)}'
            f'{line(t2 + stem_r, band[0] - 140, t2 + stem_r, band[1] + 150)}{line(t2 + right, band[0] - 140, t2 + right, band[1] + 150)}</g>'
            f'<g stroke="{ORANGE}" stroke-width="3">'
            f'{line(jx1, cy, dot_cx - r, cy)}{line(dot_cx + r, cy, t1 + stem_l, cy)}</g>'
        )
        labels = (
            f'<g fill="#9A9A96" font-family="Geist Mono, monospace" font-size="30" letter-spacing="2">'
            + "".join(text(L, y + 12, name_) for y, name_ in rules)
            + text(dot_cx, oy1 + 90, f"DOT = o × 0.98", "middle")
            + "</g>"
            f'<g fill="{ORANGE}" font-family="Geist Mono, monospace" font-size="30" letter-spacing="2">'
            + text((cut_x + t1 + stem_l) / 2, band[1] + 196, u(cut), "middle")
            + text((t2 + stem_r + t2 + right) / 2, band[1] + 196, u(right - stem_r), "middle")
            + text((t1 + stem_l + t2 + stem_r) / 2, band[1] + 196, "ONE BAR", "middle")
            + text((jx1 + dot_cx - r) / 2, cy - 50, u(dot_cx - r - jx1), "middle")
            + text((dot_cx + r + t1 + stem_l) / 2, cy - 50, u(t1 + stem_l - dot_cx - r), "middle")
            + text(cut_x, -300, f"SPUR 12 · TTO CLOSED UP {u(shift)} · j–DOT +{kern:g} · STEM {u(stem_r - stem_l)} · x-height = 100", "start")
            + "</g>"
        )
        vb = [L - 40, -jy1 - 160, R - L + 120, jy1 + 160 + 340]
    height = 320 if not guides else 560  # fixed, so every variant is drawn at the same scale
    width = round(height * vb[2] / vb[3])
    bg = f'<rect x="{vb[0]}" y="{vb[1]}" width="{vb[2]}" height="{vb[3]}" rx="90" fill="{background}"/>' if background else ""
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(f"{v:.0f}" for v in vb)}" width="{width}" height="{height}">'
        f'{bg}'
        f'<g transform="scale(1 -1)"><defs>{clip}</defs>{over}{"".join(parts)}</g>{labels}</svg>'
    )
    with open(os.path.join(OUT, f"wordmark-{name}.svg"), "w") as f:
        f.write(svg)
    print(f"wordmark-{name}.svg  spur {cut / xheight * 100:.1f} (native {native / xheight * 100:.1f}, stem {(max(stem) - stem_l) / xheight * 100:.1f})  shift {shift:.0f}")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    if sys.argv[1:] == ["satoshi"]:
        satoshi(name="satoshi-native")
        satoshi(12, name="satoshi-12")
        satoshi(12, tighten=True, name="satoshi-12-tight")
        satoshi(12, tighten=True, ink="#FFFFFF", name="satoshi-12-tight-dark")  # ground comes from the layout
        satoshi(12, tighten=True, dot="#FFFFFF", name="satoshi-12-tight-orange")
        satoshi(12, tighten=True, dot=INK, name="satoshi-12-tight-mono")
        satoshi(12, tighten=True, guides=True, kern=3, name="satoshi-construction")
    else:
        for key in sys.argv[1:] or FONTS:
            build(key)
