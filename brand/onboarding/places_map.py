"""The isometric street map on the Places onboarding page.

    python3 places_map.py light|dark noroute|pin|route|base|all > out.svg

"noroute" is the map with neither the route nor the pin and its ring: the
app draws the route and the ring itself and drops the pin in. "pin" is the
pin alone on the same canvas; "route" prints the route's points as
fractions of the canvas. They go to apple/Apps/iOS/Assets.xcassets/PlacesMap
and PlacesPin. "base" (everything but the pin) and "all" are for looking at.
"""
import math, sys
DARK = len(sys.argv) > 1 and sys.argv[1] == 'dark'
MODE = sys.argv[2] if len(sys.argv) > 2 else 'all'
L = dict(top='#FFFFFF', left='#F5F3F1', right='#E8E6E3', ink='#0A0A0A', tick='#A6A4A1', faint='#E3E1DE',
         road='#F5F3F1', park='#FBFAF7', winL='#E9E7E3', winR='#DDDBD7', door='#82807D', shadow='#E8E6E3', bg='#FFFFFF')
D = dict(top='#1F1E1C', left='#161514', right='#0F0E0D', ink='#A6A4A1', tick='#4C4A48', faint='#2A2927',
         road='#161514', park='#232220', winL='#22211F', winR='#191817', door='#656360', shadow='#141312', bg='#0A0A0A')
P = D if DARK else L
ORANGE = '#FF4F00'
def pt(x, y, z=0.0): return (201 + 15 * (x - y), 96 + 8.66 * (x + y) - z)
def f(p): return f'{p[0]:.2f},{p[1]:.2f}'
def poly(pts, fill, stroke=None, sw=1.0):
    st = f' stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round"' if stroke else ''
    return f'<polygon points="{" ".join(f(p) for p in pts)}" fill="{fill}"{st}/>'
def line(a, b, stroke, sw=0.8, cap='butt', extra=''):
    return f'<line x1="{a[0]:.2f}" y1="{a[1]:.2f}" x2="{b[0]:.2f}" y2="{b[1]:.2f}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}"{extra}/>'
def pl(pts, stroke, sw, extra=''):
    return f'<polyline points="{" ".join(f(p) for p in pts)}" fill="none" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"{extra}/>'
def dot(p, r, fill, stroke=None, sw=0.8):
    st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ''
    return f'<circle cx="{p[0]:.2f}" cy="{p[1]:.2f}" r="{r}" fill="{fill}"{st}/>'
def ell(p, rx, ry, fill, stroke=None, sw=0.8, op=None):
    st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ''
    o = f' opacity="{op}"' if op is not None else ''
    return f'<ellipse cx="{p[0]:.2f}" cy="{p[1]:.2f}" rx="{rx}" ry="{ry}" fill="{fill}"{st}{o}/>'
def rect(x0, y0, x1, y1, z, fill, stroke=None, sw=1.0):
    return poly([pt(x0, y0, z), pt(x1, y0, z), pt(x1, y1, z), pt(x0, y1, z)], fill, stroke, sw)
def box(x0, y0, x1, y1, z0, z1, sw=1.0, ink=None):
    k = ink or P['ink']
    return [poly([pt(x0, y1, z0), pt(x1, y1, z0), pt(x1, y1, z1), pt(x0, y1, z1)], P['left'], k, sw),
            poly([pt(x1, y0, z0), pt(x1, y1, z0), pt(x1, y1, z1), pt(x1, y0, z1)], P['right'], k, sw),
            rect(x0, y0, x1, y1, z1, P['top'], k, sw)]
out = []; items = []
def add(depth, parts): items.append((depth, parts))
N = 10; T = 16
# ---- base plate
out.append(poly([pt(N, 0), pt(N, N), pt(N, N, -T), pt(N, 0, -T)], P['right'], P['ink']))
out.append(poly([pt(0, N), pt(N, N), pt(N, N, -T), pt(0, N, -T)], P['left'], P['ink']))
out.append(pl([pt(0, N, -11), pt(N, N, -11), pt(N, 0, -11)], P['tick'], 0.8))
# ---- ground
out.append(rect(0, 0, N, N, 0, P['top'], P['ink']))
# ---- roads
ROADS = [(0, 4.0, N, 4.7), (5.8, 0, 6.5, N), (0, 8.0, 5.8, 8.4)]
for r in ROADS:
    out.append(rect(*r, 0, P['road'], P['tick'], 0.8))
out.append(rect(5.8, 4.0, 6.5, 4.7, 0, P['road']))
out.append(rect(5.8, 8.0, 6.5, 8.4, 0, P['road']))
# lane dashes
def dashes_x(y, x0, x1, skip):
    x = x0
    while x + 0.3 <= x1:
        if not any(a - 0.1 < x < b + 0.1 or a - 0.1 < x + 0.3 < b + 0.1 for a, b in skip):
            out.append(line(pt(x, y), pt(x + 0.3, y), P['faint'], 0.9))
        x += 0.6
def dashes_y(x, y0, y1, skip):
    y = y0
    while y + 0.3 <= y1:
        if not any(a - 0.1 < y < b + 0.1 or a - 0.1 < y + 0.3 < b + 0.1 for a, b in skip):
            out.append(line(pt(x, y), pt(x, y + 0.3), P['faint'], 0.9))
        y += 0.6
dashes_x(4.35, 0.3, N - 0.2, [(5.2, 7.1)])
dashes_y(6.15, 0.3, N - 0.2, [(3.4, 5.3), (7.6, 8.8), (8.9, 10)])
# crosswalks around the crossing
def zebra_x(x0, x1, y0, y1):  # stripes across a road running along x, stripes along y
    n = 5
    for i in range(n):
        yy0 = y0 + 0.06 + i * (y1 - y0 - 0.12) / n; yy1 = yy0 + (y1 - y0 - 0.12) / n * 0.55
        out.append(rect(x0, yy0, x1, yy1, 0, P['faint']))
def zebra_y(y0, y1, x0, x1):
    n = 5
    for i in range(n):
        xx0 = x0 + 0.06 + i * (x1 - x0 - 0.12) / n; xx1 = xx0 + (x1 - x0 - 0.12) / n * 0.55
        out.append(rect(xx0, y0, xx1, y1, 0, P['faint']))
zebra_x(5.35, 5.65, 4.0, 4.7); zebra_x(6.65, 6.95, 4.0, 4.7)
zebra_y(3.55, 3.85, 5.8, 6.5); zebra_y(4.85, 5.15, 5.8, 6.5)
# ---- park
PX0, PY0, PX1, PY1 = 6.8, 5.2, 9.5, 9.2
out.append(rect(PX0, PY0, PX1, PY1, 0, P['park'], P['tick'], 0.8))
# walkway: enters at the route, curves to the far corner
def bez(p0, p1, p2, p3, n=28):
    r = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        r.append(tuple(u**3*a + 3*u*u*t*b + 3*u*t*t*c + t**3*d for a, b, c, d in zip(p0, p1, p2, p3)))
    return r
walk = bez((PX0, 7.1), (7.6, 7.15), (8.2, 8.6), (PX1, 8.5))
out.append(pl([pt(*p) for p in walk], P['tick'], 4.4))
out.append(pl([pt(*p) for p in walk], P['road'], 3.0))
# ---- route along the side street into the park
PIN = (7.93, 7.2)
route = [pt(6.15, 9.48), pt(6.15, 7.08), pt(PX0, 7.1)] + [pt(*p) for p in walk[:12]]
route[-1] = pt(*PIN)
route_parts = [pl(route, P['ink'], 1.8, ' stroke-dasharray="0.1 4.6"'), dot(pt(6.15, 9.48), 3.2, P['top'], P['ink'], 1)]
if MODE == 'route':
    # The route for the app to draw itself, as fractions of the canvas.
    print(', '.join(f'({(x - 36) / 330:.4f}, {(y - 32) / 322:.4f})' for x, y in route)); sys.exit()
if MODE == 'ontop': ontop = route_parts
elif MODE != 'noroute': out += route_parts
# ---- buildings: (x0, y0, x1, y1, h, door side, roof kit)
B = [(0.5, 0.5, 2.3, 1.7, 34, True, 'tank'), (0.5, 2.2, 1.9, 3.6, 18, True, 'ac'), (2.8, 0.6, 5.2, 1.6, 22, False, 'ac2'),
     (2.7, 2.2, 5.2, 3.5, 46, True, 'mast'), (0.5, 5.2, 2.7, 7.4, 12, True, 'skylight'), (7.0, 0.6, 8.2, 1.8, 28, False, 'ac'),
     (3.2, 5.2, 5.2, 7.2, 26, True, 'ac2'), (8.5, 0.6, 9.5, 3.2, 16, False, 'vent'), (7.0, 2.2, 8.2, 3.4, 14, True, None),
     (0.6, 8.8, 2.6, 9.6, 10, True, None)]
def windows(x0, y0, x1, y1, h):
    parts = []
    floors = max(1, int((h - 5) // 7))
    for k in range(floors):
        z0 = 4.5 + k * 7; z1 = z0 + 3.4
        if z1 > h - 2.5: break
        # left face (y = y1)
        n = max(1, int((x1 - x0) / 0.46))
        for i in range(n):
            a = x0 + (i + 0.5) * (x1 - x0) / n - 0.08; b = a + 0.16
            parts.append(poly([pt(a, y1, z0), pt(b, y1, z0), pt(b, y1, z1), pt(a, y1, z1)], P['winL']))
        n = max(1, int((y1 - y0) / 0.46))
        for i in range(n):
            a = y0 + (i + 0.5) * (y1 - y0) / n - 0.08; b = a + 0.16
            parts.append(poly([pt(x1, a, z0), pt(x1, b, z0), pt(x1, b, z1), pt(x1, a, z1)], P['winR']))
    return parts
def cylinder(cx, cy, r, z0, z1):
    c0 = pt(cx, cy, z0); c1 = pt(cx, cy, z1); rx = r * 15 * 1.22; ry = r * 8.66 * 1.22
    body = f'<path d="M{c0[0]-rx:.2f},{c0[1]:.2f} A{rx:.2f},{ry:.2f} 0 0 0 {c0[0]+rx:.2f},{c0[1]:.2f} L{c1[0]+rx:.2f},{c1[1]:.2f} A{rx:.2f},{ry:.2f} 0 0 1 {c1[0]-rx:.2f},{c1[1]:.2f} Z" fill="{P["left"]}" stroke="{P["tick"]}" stroke-width="0.7" stroke-linejoin="round"/>'
    return [body, ell(c1, f'{rx:.2f}', f'{ry:.2f}', P['top'], P['tick'], 0.7),
            line((c0[0] - rx * 0.4, c0[1] + ry * 0.92), (c1[0] - rx * 0.4, c1[1] + ry * 0.92), P['tick'], 0.7)]
for (x0, y0, x1, y1, h, door, kit) in B:
    parts = box(x0, y0, x1, y1, 0, h)
    parts += windows(x0, y0, x1, y1, h)
    # parapet: inset line on the roof
    i = 0.12
    parts.append(pl([pt(x0 + i, y0 + i, h), pt(x1 - i, y0 + i, h), pt(x1 - i, y1 - i, h), pt(x0 + i, y1 - i, h), pt(x0 + i, y0 + i, h)], P['faint'], 0.7))
    # plinth line at the base
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if kit == 'ac':
        parts += box(cx - 0.3, cy - 0.15, cx + 0.05, cy + 0.15, h, h + 2.5, 0.7, P['tick'])
        parts.append(ell(pt(cx + 0.28, cy + 0.12, h + 0.6), 2.0, 1.15, P['top'], P['tick'], 0.7))
    elif kit == 'ac2':
        parts += box(cx - 0.6, cy - 0.15, cx - 0.25, cy + 0.15, h, h + 2.5, 0.7, P['tick'])
        parts += box(cx - 0.05, cy - 0.15, cx + 0.3, cy + 0.15, h, h + 2.5, 0.7, P['tick'])
    elif kit == 'tank':
        for (lx, ly) in [(cx - 0.18, cy - 0.18), (cx + 0.18, cy - 0.18), (cx - 0.18, cy + 0.18), (cx + 0.18, cy + 0.18)]:
            parts.append(line(pt(lx, ly, h), pt(lx, ly, h + 4), P['tick'], 0.7))
        parts += cylinder(cx, cy, 0.26, h + 4, h + 11)
    elif kit == 'mast':
        parts += box(cx - 0.35, cy - 0.3, cx + 0.25, cy + 0.25, h, h + 3.5, 0.7, P['tick'])
        m = pt(cx - 0.05, cy - 0.02, h + 4)
        parts.append(line(m, (m[0], m[1] - 10), P['tick'], 0.7))
    elif kit == 'skylight':
        parts.append(rect(x0 + 0.5, y0 + 0.5, x1 - 0.5, y1 - 0.5, h, P['winL'], P['faint'], 0.7))
    elif kit == 'vent':
        for k in range(3):
            parts.append(ell(pt(cx, y0 + 0.5 + k * 0.7, h + 0.5), 1.8, 1.0, P['top'], P['tick'], 0.7))
    add(x1 + y1, parts)
# ---- street lamps along the side street, and benches
def lamp(x, y, side):
    g = pt(x, y); t = pt(x, y, 13)
    return [line(g, t, P['tick'], 0.7), line(t, (t[0] + 3 * side, t[1] + 1.7), P['tick'], 0.7)]
for (x, y) in [(6.62, 2.9), (6.62, 6.2)]:
    add(x + y, lamp(x, y, -1))
def bench(x, y):
    return box(x, y, x + 0.4, y + 0.14, 1.6, 2.6, 0.7) + [line(pt(x + 0.05, y + 0.14, 0), pt(x + 0.05, y + 0.14, 1.6), P['ink'], 0.7), line(pt(x + 0.35, y + 0.14, 0), pt(x + 0.35, y + 0.14, 1.6), P['ink'], 0.7)]
# ---- trees: crown, highlight arc, trunk, shadow
def tree(x, y, r=6.0, h=8):
    g = pt(x, y); c = (g[0], g[1] - h - r + 2)
    return [ell(g, r, r * 0.55, P['shadow']), line(g, (g[0], g[1] - h + 1), P['ink'], 1),
            dot(c, r, P['top'], P['ink'], 1),
            f'<path d="M{c[0]-r*0.55:.2f},{c[1]-r*0.15:.2f} A{r*0.6:.2f},{r*0.6:.2f} 0 0 1 {c[0]+r*0.1:.2f},{c[1]-r*0.62:.2f}" fill="none" stroke="{P["tick"]}" stroke-width="0.8" stroke-linecap="round"/>']
def inv(sx, sy):
    a = (sx - 201) / 15; b = (sy - 96) / 8.66; return ((a + b) / 2, (b - a) / 2)
for s in [(234, 209), (250, 221.5), (241, 233), (204, 249), (226, 246), (262, 236)]:
    x, y = inv(*s)
    if x > PX1 - 0.15: continue
    add(x + y, tree(x, y))
# ---- pin with a ring on the ground
x, y = pt(*PIN)
pin = [ell((x, y), 12, 6.6, 'none', P['faint'] if not DARK else P['tick'], 0.8), ell((x, y), 8, 4.4, '#000000' if DARK else P['ink'], op=0.55 if DARK else 0.12),
       f'<path d="M{x},{y} C{x-4},{y-14} {x-16},{y-22} {x-16},{y-36} A16,16 0 1 1 {x+16},{y-36} C{x+16},{y-22} {x+4},{y-14} {x},{y} Z" fill="{ORANGE}" stroke="{P["ink"] if DARK else "#0A0A0A"}" stroke-width="1" stroke-linejoin="round"/>',
       dot((x, y - 36), 5.5, '#FFFFFF', P['ink'] if DARK else '#0A0A0A', 1)]
if MODE == 'all': add(PIN[0] + PIN[1] + 0.01, pin)
elif MODE in ('base', 'ontop'): add(PIN[0] + PIN[1] + 0.01, pin[:2])
for _, parts in sorted(items, key=lambda t: t[0]):
    out += parts
if MODE == 'pin': out = pin[2:]
if MODE == 'ontop': out += ontop
svg = (f'<svg width="402" height="392" viewBox="36 32 330 322" xmlns="http://www.w3.org/2000/svg">'
       + ''.join(out) + '</svg>')
print(svg)
