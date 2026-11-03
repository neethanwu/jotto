"""Jotto logo v1, final art.

    brand/.venv/bin/python brand/logo/final.py   -> brand/logo/final/*

The wordmark is Satoshi Bold's j, t and o with the first o replaced by the
live dot. Both t's are rebuilt as one shape: two stems and a single bar whose
left spur is cut to 12 (x-height = 100) and whose right end is Satoshi's own.
Everything in ink is merged into one outline with skia-pathops, so there are
no seams where the bar meets the stems.

Spacing, in x-height hundredths:
  j to dot   +3 over Satoshi's own (17 -> 20 at the dot's equator)
  dot to tt  closed up 7, what the spur lost
  tt to o    Satoshi's own

Icons follow the "D-40" spec: orange ground, white dot, ink bar; per 100 of
dot, gap 18, bar 72 long and 40 thick. Favicons are redrawn on the pixel grid.
"""

import math
import os
import sys

import pathops
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from refs import FONTS, load  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "final")
ORANGE = "#FF4F00"
INK = "#0A0A0A"
WHITE = "#FFFFFF"

SPUR = 12  # left overhang of the shared bar
KERN_J_DOT = 3


def glyph_path(font, char, dx=0):
    glyphs = font.getGlyphSet()
    path = pathops.Path()
    glyphs[font.getBestCmap()[ord(char)]].draw(TransformPen(path.getPen(), (1, 0, 0, 1, dx, 0)))
    return path


def rect(x0, y0, x1, y1):
    path = pathops.Path()
    pen = path.getPen()
    pen.moveTo((x0, y0)); pen.lineTo((x1, y0)); pen.lineTo((x1, y1)); pen.lineTo((x0, y1)); pen.closePath()
    return path


def circle(cx, cy, r):
    k = r * 0.5522847498
    path = pathops.Path()
    pen = path.getPen()
    pen.moveTo((cx + r, cy))
    pen.curveTo((cx + r, cy + k), (cx + k, cy + r), (cx, cy + r))
    pen.curveTo((cx - k, cy + r), (cx - r, cy + k), (cx - r, cy))
    pen.curveTo((cx - r, cy - k), (cx - k, cy - r), (cx, cy - r))
    pen.curveTo((cx + k, cy - r), (cx + r, cy - k), (cx + r, cy))
    pen.closePath()
    return path


def union(paths):
    return pathops.op(paths[0], paths[1], pathops.PathOp.UNION) if len(paths) == 2 else pathops.op(paths[0], union(paths[1:]), pathops.PathOp.UNION)


def wordmark_paths():
    """Ink and dot outlines in font units, y up."""
    path, index, _ = FONTS["satoshi"]
    font = load(path, index)
    xh = font["OS/2"].sxHeight
    track = -0.01 * font["head"].unitsPerEm
    adv = lambda c: font["hmtx"][font.getBestCmap()[ord(c)]][0]

    # Satoshi's t is a plain cross: read its stem and bar straight from the outline.
    pen = RecordingPen()
    font.getGlyphSet()[font.getBestCmap()[ord("t")]].draw(pen)
    points = [pt for _, pts in pen.value for pt in pts]
    bar_l, stem_l, stem_r, bar_r = sorted({x for x, _ in points})
    _, bar_b, bar_t, top = sorted({y for _, y in points})
    native = stem_l - bar_l
    cut = SPUR / 100 * xh
    shift = native - cut

    o = glyph_path(font, "o")
    ox0, oy0, ox1, oy1 = o.bounds
    jdot = adv("j") + track + KERN_J_DOT / 100 * xh
    dot = circle(jdot + (ox0 + ox1) / 2, (oy0 + oy1) / 2, (oy1 - oy0) / 2 * 0.98)
    t1 = jdot + adv("o") + track - shift
    t2 = t1 + adv("t") + track
    ox = t2 + adv("t") + track
    ink = union([
        glyph_path(font, "j"),
        rect(t1 + stem_l, 0, t1 + stem_r, top),
        rect(t2 + stem_l, 0, t2 + stem_r, top),
        rect(t1 + stem_l - cut, bar_b, t2 + bar_r, bar_t),
        glyph_path(font, "o", ox),
    ])
    return ink, dot


def d_of(path, flip_y):
    pen = SVGPathPen(None)
    path.draw(TransformPen(pen, (1, 0, 0, -1, 0, flip_y)))
    return pen.getCommands()


def write_wordmarks():
    ink, dot = wordmark_paths()
    x0, y0, x1, y1 = union([ink, dot]).bounds
    w, h = x1 - x0, y1 - y0
    variants = {
        "wordmark": (INK, ORANGE),
        "wordmark-dark": (WHITE, ORANGE),
        "wordmark-on-orange": (INK, WHITE),
        "wordmark-mono": (INK, INK),
        "wordmark-mono-white": (WHITE, WHITE),
    }
    height = 120
    for name, (ink_c, dot_c) in variants.items():
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0:.0f} 0 {w:.0f} {h:.0f}" '
            f'width="{round(height * w / h)}" height="{height}" role="img" aria-label="jotto">'
            f'<path d="{d_of(ink, y1)}" fill="{ink_c}"/><path d="{d_of(dot, y1)}" fill="{dot_c}"/></svg>'
        )
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(svg)
    print(f"wordmarks: {len(variants)}, aspect {w / h:.3f}")


# ── Icons ────────────────────────────────────────────────────────────────────
# Geometry in a 1024 tile. The dot and bar are measured in "dot units" (dot
# diameter 100) and scaled by K. The pair is centred on its box, nudged right
# 3 units because the dot carries more weight than the bar.

GAP, LENGTH, WEIGHT = 18, 72, 40


def icon_geometry(size=1024, k=0.46 * 1024 / 120):
    width = 100 + GAP + LENGTH
    left = size / 2 - width * k / 2 + 3 * k
    cx, cy, r = left + 50 * k, size / 2, 50 * k
    bar = (left + (100 + GAP) * k, cy - WEIGHT / 2 * k, left + width * k, cy + WEIGHT / 2 * k)
    return cx, cy, r, bar


def squircle(size, corner=0.31, n=3.4, steps=90):
    """The iOS icon mask: straight edges, with each corner a superellipse quarter so the
    curvature eases in (a continuous corner, not a circle). `corner` is how far along each
    edge the curve starts, as a share of the size."""
    c = size * corner
    pts = []
    sg = lambda v, e: math.copysign(abs(v) ** e, v)
    for k, (cx, cy) in enumerate(((size - c, c), (size - c, size - c), (c, size - c), (c, c))):
        for i in range(steps + 1):
            t = -math.pi / 2 + math.pi / 2 * (k + i / steps)
            pts.append((cx + c * sg(math.cos(t), 2 / n), cy + c * sg(math.sin(t), 2 / n)))
    return pts


def icon_svg(shape, k_scale=1.0):
    size = 1024
    cx, cy, r, (bx0, by0, bx1, by1) = icon_geometry(size, 0.46 * 1024 / 120 * k_scale)
    ground = {
        "square": f'<rect width="{size}" height="{size}" fill="{ORANGE}"/>',
        "squircle": f'<path d="M{" L".join(f"{x:.1f} {y:.1f}" for x, y in squircle(size))} Z" fill="{ORANGE}"/>',
        "circle": f'<circle cx="512" cy="512" r="512" fill="{ORANGE}"/>',
    }[shape]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}">'
        f'{ground}<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{WHITE}"/>'
        f'<rect x="{bx0:.1f}" y="{by0:.1f}" width="{bx1 - bx0:.1f}" height="{by1 - by0:.1f}" fill="{INK}"/></svg>'
    )


def icon_png(path, size, shape="square", k_scale=1.0, ss=4):
    big = size * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    if shape == "square":
        draw.rectangle((0, 0, big, big), fill=ORANGE)
    elif shape == "squircle":
        draw.polygon(squircle(big), fill=ORANGE)
    else:
        draw.ellipse((0, 0, big - 1, big - 1), fill=ORANGE)
    cx, cy, r, bar = icon_geometry(big, 0.46 * big / 120 * k_scale)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=WHITE)
    draw.rectangle(bar, fill=INK)
    out = img.resize((size, size), Image.BOX)
    # App Store icons must be opaque; only the masked previews keep alpha.
    (out.convert("RGB") if shape == "square" else out).save(path)


# Favicons, drawn on the pixel grid: (tile, corner radius, dot box, bar box).
# At these sizes the dot grows and the bar thickens a little so both survive.
FAVICONS = {
    16: (4, (1, 4, 9, 12), (10, 6, 15, 10)),
    32: (7, (3, 9, 17, 23), (20, 13, 30, 19)),
}


def favicon_png(size, ss=8):
    radius, dot, bar = FAVICONS[size]
    img = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((0, 0, size * ss - 1, size * ss - 1), radius * ss, fill=ORANGE)
    box = lambda b: (b[0] * ss, b[1] * ss, b[2] * ss - 1, b[3] * ss - 1)  # Pillow's ends are inclusive
    draw.ellipse(box(dot), fill=WHITE)
    draw.rectangle(box(bar), fill=INK)
    return img.resize((size, size), Image.BOX)


def favicon_svg():
    radius, (dx0, dy0, dx1, dy1), (bx0, by0, bx1, by1) = FAVICONS[32]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
        f'<rect width="32" height="32" rx="{radius}" fill="{ORANGE}"/>'
        f'<circle cx="{(dx0 + dx1) / 2}" cy="{(dy0 + dy1) / 2}" r="{(dx1 - dx0) / 2}" fill="{WHITE}"/>'
        f'<rect x="{bx0}" y="{by0}" width="{bx1 - bx0}" height="{by1 - by0}" fill="{INK}"/></svg>'
    )


def write_icon_composer():
    """AppIcon.icon for Icon Composer / Xcode 26: the system renders Liquid Glass
    and the dark, tinted and clear looks from it. In dark the ground goes ink
    and the dot takes the orange, so the bar turns white; in tinted and clear
    the bar is white at 60% so the dot still leads."""
    import json

    bundle = os.path.join(OUT, "AppIcon.icon")
    os.makedirs(os.path.join(bundle, "Assets"), exist_ok=True)
    cx, cy, r, (bx0, by0, bx1, by1) = icon_geometry()
    layer = lambda shape: f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{shape}</svg>\n'
    with open(os.path.join(bundle, "Assets", "dot.svg"), "w") as f:
        f.write(layer(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{WHITE}"/>'))
    with open(os.path.join(bundle, "Assets", "bar.svg"), "w") as f:
        f.write(layer(f'<rect x="{bx0:.1f}" y="{by0:.1f}" width="{bx1 - bx0:.1f}" height="{by1 - by0:.1f}" fill="{INK}"/>'))
    srgb = lambda hex_, a=1.0: "srgb:" + ",".join(f"{int(hex_[i:i + 2], 16) / 255:.3f}" for i in (1, 3, 5)) + f",{a:.3f}"
    doc = {
        "fill": {"solid": srgb(ORANGE)},
        "groups": [{
            "layers": [
                {"glass": False, "image-name": "dot.svg", "name": "dot"},
                {
                    "glass": False, "image-name": "bar.svg", "name": "bar",
                    "fill-specializations": [
                        {"appearance": "dark", "value": {"solid": srgb(WHITE)}},
                        {"appearance": "tinted", "value": {"solid": srgb(WHITE, 0.6)}},
                    ],
                },
            ],
            "shadow": {"kind": "neutral", "opacity": 0.3},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(bundle, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


def write_icons():
    files = {
        "icon-ios.svg": icon_svg("square"),  # full bleed: iOS applies the mask
        "icon-ios-masked.svg": icon_svg("squircle"),  # for mockups and the site
        "icon-watch.svg": icon_svg("square", 0.88),  # watchOS crops to a circle
        "icon-watch-masked.svg": icon_svg("circle", 0.88),
        "favicon.svg": favicon_svg(),
    }
    for name, text in files.items():
        with open(os.path.join(OUT, name), "w") as f:
            f.write(text)
    icon_png(os.path.join(OUT, "icon-ios-1024.png"), 1024)
    icon_png(os.path.join(OUT, "icon-watch-1024.png"), 1024, k_scale=0.88)
    icon_png(os.path.join(OUT, "apple-touch-icon.png"), 180)
    f16, f32 = favicon_png(16), favicon_png(32)
    f16.save(os.path.join(OUT, "favicon-16.png"))
    f32.save(os.path.join(OUT, "favicon-32.png"))
    f32.save(os.path.join(OUT, "favicon.ico"), sizes=[(16, 16), (32, 32)], append_images=[f16])
    print(f"icons: {len(files) + 6} files")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write_wordmarks()
    write_icons()
    write_icon_composer()
