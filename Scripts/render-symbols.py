#!/usr/bin/env python3
"""Generates the app's custom SF Symbols (App/Assets.xcassets/*.symbolset).

    python3 Scripts/render-symbols.py

Each symbol has two layers for hierarchical (two-tone) rendering: the body in
the primary tone, surfaces such as lenses, cones and grilles in the secondary
tone. Only the Regular-M glyph is drawn; the system scales it for other weights
and sizes. Coordinates are template units: baseline at y = 0, cap height at
y = -70.5; the regular stroke weight is about 9 units, and gaps between
layers are at least 6 so they stay visible at 13 pt.

After changing a drawing, bump its revision in IconRenderer.customSymbols so
icon files that Core Audio already hands out are rendered again.
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "App", "Assets.xcassets")


def f(v):
    return f"{v:g}"


class Path:
    """Shapes of one layer. Holes run counter-clockwise (nonzero fill)."""

    def __init__(self):
        self.parts = []
        self.box = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    def _grow(self, x0, y0, x1, y1):
        b = self.box
        self.box = [min(b[0], x0), min(b[1], y0), max(b[2], x1), max(b[3], y1)]

    def rect(self, x0, y0, x1, y1, r=0, hole=False):
        r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
        if not hole:
            self._grow(x0, y0, x1, y1)
        if r == 0:
            pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
            if hole:
                pts.reverse()
            self.parts.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in pts) + " Z")
            return self
        if not hole:
            d = (f"M{f(x0 + r)} {f(y0)} H{f(x1 - r)} A{f(r)} {f(r)} 0 0 1 {f(x1)} {f(y0 + r)} "
                 f"V{f(y1 - r)} A{f(r)} {f(r)} 0 0 1 {f(x1 - r)} {f(y1)} H{f(x0 + r)} "
                 f"A{f(r)} {f(r)} 0 0 1 {f(x0)} {f(y1 - r)} V{f(y0 + r)} A{f(r)} {f(r)} 0 0 1 {f(x0 + r)} {f(y0)} Z")
        else:
            d = (f"M{f(x0 + r)} {f(y0)} A{f(r)} {f(r)} 0 0 0 {f(x0)} {f(y0 + r)} V{f(y1 - r)} "
                 f"A{f(r)} {f(r)} 0 0 0 {f(x0 + r)} {f(y1)} H{f(x1 - r)} A{f(r)} {f(r)} 0 0 0 {f(x1)} {f(y1 - r)} "
                 f"V{f(y0 + r)} A{f(r)} {f(r)} 0 0 0 {f(x1 - r)} {f(y0)} Z")
        self.parts.append(d)
        return self

    def ellipse(self, cx, cy, rx, ry=None, hole=False):
        ry = rx if ry is None else ry
        if not hole:
            self._grow(cx - rx, cy - ry, cx + rx, cy + ry)
        s = 0 if hole else 1
        self.parts.append(
            f"M{f(cx - rx)} {f(cy)} A{f(rx)} {f(ry)} 0 1 {s} {f(cx + rx)} {f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 {s} {f(cx - rx)} {f(cy)} Z")
        return self

    def raw(self, d, box):
        self.parts.append(d)
        self._grow(*box)
        return self

    def d(self):
        return " ".join(self.parts)


def soundbar():
    """Soundbar with a driver near each end."""
    body = Path().rect(0, -60, 140, -12, r=14)
    cones = Path()
    for cx in (28, 112):
        body.ellipse(cx, -36, 15, hole=True)
        cones.ellipse(cx, -36, 9)
    return body, cones


def webcam():
    """A current bar-style webcam on a small stand."""
    body = Path().rect(0, -70, 108, -26, r=22).ellipse(54, -48, 15, hole=True)
    body.rect(48, -28, 60, -12).rect(30, -14, 78, -4, r=5)
    lens = Path().ellipse(54, -48, 9)
    return body, lens


def camera():
    """Mirrorless camera, front view: big lens, centered viewfinder."""
    body = Path().rect(0, -62, 120, -2, r=14).ellipse(60, -32, 23, hole=True)
    body.rect(40, -75, 80, -58, r=7).rect(10, -67, 30, -59, r=3)
    lens = Path().ellipse(60, -32, 16)
    return body, lens


def desk_microphone():
    """Angular desk microphone: grille head, body with a dial, stand."""
    head = Path().raw(
        "M14 -86 H48 A8 8 0 0 1 56 -78 V-48 H6 V-78 A8 8 0 0 1 14 -86 Z", (6, -86, 56, -48))
    body = Path().raw(
        "M6 -42 H56 V-28 A8 8 0 0 1 48 -20 H14 A8 8 0 0 1 6 -28 Z", (6, -42, 56, -20))
    body.ellipse(31, -31, 5, hole=True)
    body.rect(26, -21, 36, 0).rect(0, -2, 62, 8, r=5)
    return body, head


def stand_microphone():
    """Two-tone "mic": grille capsule in a holder on a stand."""
    capsule = Path().rect(14, -80, 46, -30, r=16)
    # Holder: a half ring around the lower capsule with round ends.
    cx, cy, outer, inner = 30, -46, 30, 22
    cap = (outer - inner) / 2
    holder = Path().raw(
        f"M{cx - outer} {cy} A{outer} {outer} 0 0 0 {cx + outer} {cy} "
        f"A{f(cap)} {f(cap)} 0 0 0 {cx + inner} {cy} "
        f"A{inner} {inner} 0 0 1 {cx - inner} {cy} "
        f"A{f(cap)} {f(cap)} 0 0 0 {cx - outer} {cy} Z",
        (cx - outer, cy - cap, cx + outer, cy + outer))
    holder.rect(26, -17, 34, 2).rect(12, 0, 48, 8, r=4)
    return holder, capsule


def handheld_microphone():
    """Two-tone "music.mic": grille ball and a tapered handle."""
    import math
    head_x, head_y, head_r, gap = 66, -63, 18, 6
    end_x, end_y = 12, 1
    length = math.hypot(end_x - head_x, end_y - head_y)
    ux, uy = (end_x - head_x) / length, (end_y - head_y) / length
    nx, ny = -uy, ux
    start = head_r + gap
    sx, sy = head_x + start * ux, head_y + start * uy
    ex, ey = head_x + length * ux, head_y + length * uy
    top, bottom = 10, 5.5

    def p(x, y):
        return f"{x:.2f} {y:.2f}"

    handle = Path().raw(
        f"M{p(sx - top * nx, sy - top * ny)} L{p(sx + top * nx, sy + top * ny)} "
        f"L{p(ex + bottom * nx, ey + bottom * ny)} "
        f"A{bottom} {bottom} 0 0 1 {p(ex - bottom * nx, ey - bottom * ny)} Z",
        (ex - bottom, sy - top, sx + top, ey + bottom))
    head = Path().ellipse(head_x, head_y, head_r)
    return handle, head


def speakerphone():
    """Conference speakerphone puck seen from above: control top, fabric side."""
    rx, ry, cy, depth = 58, 24, -44, 18
    top = Path().ellipse(rx, cy, rx, ry).ellipse(rx, cy, 18, 7.5, hole=True)
    fabric = Path().raw(
        f"M0 {cy} A{rx} {ry} 0 0 0 {2 * rx} {cy} V{cy + depth} A{rx} {ry} 0 0 1 0 {cy + depth} Z",
        (0, cy, 2 * rx, cy + depth + ry))
    fabric.ellipse(rx, cy, 18, 7.5)
    return top, fabric


# Name -> (drawing, scale). The scale matches each drawing's size to
# comparable SF Symbols, which run well past the cap height (a microphone
# spans about 110 units).
SYMBOLS = {
    "soundbar": (soundbar, 1.1),
    "webcam": (webcam, 1.2),
    "mirrorless.camera": (camera, 1.15),
    "desk.microphone": (desk_microphone, 1.2),
    "speakerphone": (speakerphone, 1.2),
    "mic.twotone": (stand_microphone, 1.25),
    "music.mic.twotone": (handheld_microphone, 1.25),
}


def transform(d, scale, dx, dy):
    """Scales and moves path data (M, L, H, V, A and Z commands only)."""
    tokens = re.findall(r"[MLHVAZ]|-?\d*\.?\d+", d)
    out, i, cmd = [], 0, None
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            cmd = t
            out.append(t)
            i += 1
        elif cmd in ("M", "L"):
            out += [f(float(t) * scale + dx), f(float(tokens[i + 1]) * scale + dy)]
            i += 2
        elif cmd == "H":
            out.append(f(float(t) * scale + dx))
            i += 1
        elif cmd == "V":
            out.append(f(float(t) * scale + dy))
            i += 1
        elif cmd == "A":
            rx, ry, rotation, large, sweep, x, y = tokens[i:i + 7]
            out += [f(float(rx) * scale), f(float(ry) * scale), rotation, large, sweep,
                    f(float(x) * scale + dx), f(float(y) * scale + dy)]
            i += 7
        else:
            raise ValueError(f"unsupported path data near {t!r}")
    return " ".join(out)

GUIDES = """  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>"""

STYLE = """ <style>.monochrome-0 {-sfsymbols-motion-group:1}
.monochrome-1 {-sfsymbols-motion-group:0}
.multicolor-0:tintColor {-sfsymbols-motion-group:1;fill:#007AFF}
.multicolor-1:tintColor {-sfsymbols-motion-group:0;fill:#007AFF}
.hierarchical-0:secondary {-sfsymbols-motion-group:1;fill:#8E8E8E}
.hierarchical-1:primary {-sfsymbols-motion-group:0;fill:#000000}
.SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
</style>"""


def write(name, build, scale):
    primary, secondary = build()
    # Scale around the drawing's center so it stays where it was drawn.
    box = [min(primary.box[0], secondary.box[0]), min(primary.box[1], secondary.box[1]),
           max(primary.box[2], secondary.box[2]), max(primary.box[3], secondary.box[3])]
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    dx, dy = cx - cx * scale, cy - cy * scale
    primary_d = transform(primary.d(), scale, dx, dy)
    secondary_d = transform(secondary.d(), scale, dx, dy)
    x0, x1 = box[0] * scale + dx, box[2] * scale + dx
    left = 1391.3
    tx = left - x0
    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- Generated by Scripts/render-symbols.py; edit the script, not this file. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
{STYLE}
 <g id="Notes">
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">Template v.6.0</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 352)">{name} for Simple Audio Manager</text>
 </g>
 <g id="Guides">
{GUIDES}
  <line id="left-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{f(left)}" x2="{f(left)}" y1="1030.79" y2="1150.12"/>
  <line id="right-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{f(round(tx + x1, 2))}" x2="{f(round(tx + x1, 2))}" y1="1030.79" y2="1150.12"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {f(round(tx, 2))} 1126)">
   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:secondary SFSymbolsPreviewWireframe" d="{secondary_d}"/>
   <path class="monochrome-1 multicolor-1:tintColor hierarchical-1:primary SFSymbolsPreviewWireframe" d="{primary_d}"/>
  </g>
 </g>
</svg>
"""
    folder = os.path.join(ASSETS, f"{name}.symbolset")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"{name}.svg"), "w") as fh:
        fh.write(svg)
    contents = {
        "info": {"author": "xcode", "version": 1},
        "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}],
    }
    with open(os.path.join(folder, "Contents.json"), "w") as fh:
        json.dump(contents, fh, indent=2)
        fh.write("\n")
    print(f"{name}: {f(round(x1 - x0, 1))} x {f(round((box[3] - box[1]) * scale, 1))} units")


if __name__ == "__main__":
    for symbol_name, (builder, symbol_scale) in SYMBOLS.items():
        write(symbol_name, builder, symbol_scale)
