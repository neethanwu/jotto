"""Jotto colour, v1.

    python3 -I brand/color/build.py   -> brand/color/tokens.json, tokens.css

Two scales, both built in OKLCH so equal steps look equal:
  orange  anchored on the brand orange #FF4F00 at 500
  ink     the neutrals: from paper to the logo's ink #0A0A0A, with a trace of
          warmth (hue 75) so the greys sit with the orange instead of going blue

Then semantic roles for light and dark, each checked for WCAG contrast.
Status colours (success, warning, error) are left to the platform: iOS system
colours in the apps.
"""

import json
import math
import os

OUT = os.path.dirname(os.path.abspath(__file__))


# ── Colour math ──────────────────────────────────────────────────────────────

def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def hex_to_rgb(h):
    return [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]


def rgb_to_hex(rgb):
    return "#" + "".join(f"{round(max(0, min(1, c)) * 255):02X}" for c in rgb)


def oklab_from_rgb(rgb):
    r, g, b = (srgb_to_linear(c) for c in rgb)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def rgb_from_oklch(L, C, h):
    a, b = C * math.cos(math.radians(h)), C * math.sin(math.radians(h))
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    lin = (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
           -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
           -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    return [linear_to_srgb(c) if c > 0 else 0 for c in lin], all(-1e-4 <= c <= 1 + 1e-4 for c in lin)


def oklch(hex_):
    L, a, b = oklab_from_rgb(hex_to_rgb(hex_))
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def in_gamut(L, C, h):
    """Largest chroma up to C that sRGB can show at this lightness and hue."""
    lo, hi = 0.0, C
    if rgb_from_oklch(L, C, h)[1]:
        return rgb_to_hex(rgb_from_oklch(L, C, h)[0])
    for _ in range(30):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if rgb_from_oklch(L, mid, h)[1] else (lo, mid)
    return rgb_to_hex(rgb_from_oklch(L, lo, h)[0])


def luminance(hex_):
    r, g, b = (srgb_to_linear(c) for c in hex_to_rgb(hex_))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


# ── Scales ───────────────────────────────────────────────────────────────────

BRAND = "#FF4F00"
INK = "#0A0A0A"
STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]


def orange_scale():
    L0, C0, h0 = oklch(BRAND)
    lightness = {50: 0.975, 100: 0.945, 200: 0.89, 300: 0.82, 400: 0.74, 600: 0.57, 700: 0.49, 800: 0.41, 900: 0.33, 950: 0.25}
    scale = {}
    for step in STEPS:
        if step == 500:
            scale[step] = BRAND
            continue
        L = lightness[step]
        # Chroma peaks at the brand step and eases off toward paper and ink;
        # the darks lean 4 degrees toward red so they read as burnt, not brown.
        C = C0 * (1 - abs(L - L0) / (1 - L0) * 0.55) if L > L0 else C0 * (0.55 + 0.45 * (L - 0.2) / (L0 - 0.2))
        h = h0 if L > L0 else h0 - 4 * (L0 - L) / (L0 - 0.25)
        scale[step] = in_gamut(L, C, h)
    return scale


def ink_scale():
    lightness = {50: 0.985, 100: 0.965, 200: 0.925, 300: 0.87, 400: 0.72, 500: 0.6, 600: 0.5, 700: 0.41, 800: 0.32, 900: 0.235}
    scale = {0: "#FFFFFF"}
    for step in STEPS:
        if step == 950:
            scale[step] = INK
            continue
        L = lightness[step]
        scale[step] = in_gamut(L, 0.0035 + 0.002 * (1 - abs(L - 0.6) / 0.4), 75)
    return scale


# ── Roles ────────────────────────────────────────────────────────────────────
# (role, light value, dark value, minimum contrast against its ground, ground role)

def roles(o, k):
    return [
        ("bg", k[0], k[950], None, None),
        ("surface", k[50], k[900], None, None),
        ("surface-raised", k[0], k[800], None, None),
        ("border", k[200], k[700], None, None),
        ("text", k[950], k[50], 7.0, "bg"),
        ("text-secondary", k[600], k[400], 4.5, "bg"),
        ("text-tertiary", k[500], k[500], 3.0, "bg"),
        ("accent", o[500], o[500], 3.0, "bg"),  # the dot, record button, focus: not body text
        ("accent-text", o[600], o[500], 4.5, "bg"),  # orange that can be read: links, inline labels. On ink the brand orange itself reads.
        ("accent-text-large", o[500], o[500], 3.0, "bg"),  # large text only: 24px regular or 19px bold and up
        ("accent-subtle", o[50], o[950], None, None),  # tinted rows, selection
        ("on-accent", k[0], k[0], None, None),
    ]


def main():
    o, k = orange_scale(), ink_scale()
    table = roles(o, k)
    report = []
    for name, light, dark, need, ground in table:
        if need:
            gl = next(r for r in table if r[0] == ground)
            cl, cd = contrast(light, gl[1]), contrast(dark, gl[2])
            ok = "ok" if min(cl, cd) >= need else "LOW"
            sl = next(r for r in table if r[0] == "surface")
            report.append(f"{name:16} light {light} {cl:5.2f} ({contrast(light, sl[1]):.2f} on surface)  dark {dark} {cd:5.2f} ({contrast(dark, sl[2]):.2f})  need {need}  {ok}")
    tokens = {
        "orange": {str(s): v for s, v in o.items()},
        "ink": {str(s): v for s, v in k.items()},
        "light": {r[0]: r[1] for r in table},
        "dark": {r[0]: r[2] for r in table},
    }
    with open(os.path.join(OUT, "tokens.json"), "w") as f:
        json.dump(tokens, f, indent=2)
        f.write("\n")
    css = [":root {"]
    css += [f"  --orange-{s}: {v};" for s, v in o.items()]
    css += [f"  --ink-{s}: {v};" for s, v in k.items()]
    css += [f"  --{r[0]}: {r[1]};" for r in table]
    css += ["}", "", "@media (prefers-color-scheme: dark) {", "  :root {"]
    css += [f"    --{r[0]}: {r[2]};" for r in table]
    css += ["  }", "}"]
    with open(os.path.join(OUT, "tokens.css"), "w") as f:
        f.write("/* Jotto colour v1. Generated by brand/color/build.py; edit there. */\n" + "\n".join(css) + "\n")
    print("orange", " ".join(f"{s}:{v}" for s, v in o.items()))
    print("ink   ", " ".join(f"{s}:{v}" for s, v in k.items()))
    print("\n".join(report))
    print("orange on white per step:", " ".join(f"{s}:{contrast(v, '#FFFFFF'):.2f}" for s, v in o.items()))
    print("orange on ink per step:  ", " ".join(f"{s}:{contrast(v, INK):.2f}" for s, v in o.items()))


if __name__ == "__main__":
    main()
