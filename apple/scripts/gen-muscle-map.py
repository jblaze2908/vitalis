#!/usr/bin/env python3
"""Generate VitalisUI/MuscleMap/MuscleMapPaths.swift from briefs/assets/muscle-map-paths.json.

Run by hand from apple/: python3 scripts/gen-muscle-map.py. Stdlib only; output is committed.
"""
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "briefs/assets/muscle-map-paths.json"
OUT = ROOT / "VitalisKit/Sources/VitalisUI/MuscleMap/MuscleMapPaths.swift"

MIT = """MIT License

Copyright (c) 2022 ELABBASSI Hicham

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

ARITY = {"M": 2, "L": 2, "Q": 4, "C": 6, "A": 7, "Z": 0}
TOKEN = re.compile(r"[MLCQAZ]|-?\d*\.?\d+(?:e-?\d+)?", re.I)
stats = {"arcs": 0, "degenerate": 0, "arc_cubics": 0, "ops": 0}


def parse(d):
    """Yield (cmd, args) with implicit repeats expanded (M repeats as L)."""
    tokens = TOKEN.findall(d)
    i, cmd = 0, None
    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            if t != t.upper():
                sys.exit(f"relative command {t} not supported")
            cmd = t
            i += 1
            if cmd == "Z":
                yield "Z", []
                continue
        elif cmd is None or cmd == "Z":
            sys.exit(f"number without command at token {i}")
        n = ARITY[cmd]
        args = [float(x) for x in tokens[i:i + n]]
        if len(args) != n:
            sys.exit(f"truncated {cmd} at token {i}")
        i += n
        yield cmd, args
        if cmd == "M":
            cmd = "L"


def arc_to_cubics(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """SVG endpoint arc -> list of cubic (c1x, c1y, c2x, c2y, x, y); SVG 1.1 F.6.5/F.6.6."""
    stats["arcs"] += 1
    if x1 == x2 and y1 == y2:
        stats["degenerate"] += 1
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [(x1, y1, x2, y2, x2, y2)]
    phi = math.radians(phi_deg % 360)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0.0, num / den))
    if large == sweep:
        coef = -coef
    cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta1 = angle(1, 0, ux, uy)
    delta = angle(ux, uy, vx, vy)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    segs = max(1, math.ceil(abs(delta) / (math.pi / 2) - 1e-9))
    step = delta / segs
    k = 4 / 3 * math.tan(step / 4)

    def point(t):
        ex, ey = rx * math.cos(t), ry * math.sin(t)
        return cp * ex - sp * ey + cx, sp * ex + cp * ey + cy

    def deriv(t):
        ex, ey = -rx * math.sin(t), ry * math.cos(t)
        return cp * ex - sp * ey, sp * ex + cp * ey

    out = []
    for s in range(segs):
        a, b = theta1 + s * step, theta1 + (s + 1) * step
        p0, p3 = point(a), point(b)
        d0, d3 = deriv(a), deriv(b)
        c1 = (p0[0] + k * d0[0], p0[1] + k * d0[1])
        c2 = (p3[0] - k * d3[0], p3[1] - k * d3[1])
        if s == segs - 1:
            p3 = (x2, y2)
        out.append((*c1, *c2, *p3))
    stats["arc_cubics"] += len(out)
    return out


def num(v):
    r = round(v, 3)
    if r == int(r):
        return str(int(r))
    return f"{r:.3f}".rstrip("0")


def ops_for(d):
    ops, cx, cy, sx, sy = [], 0.0, 0.0, 0.0, 0.0
    for cmd, a in parse(d):
        if cmd == "M":
            ops.append(f".move({num(a[0])}, {num(a[1])})")
            cx, cy = sx, sy = a[0], a[1]
        elif cmd == "L":
            ops.append(f".line({num(a[0])}, {num(a[1])})")
            cx, cy = a
        elif cmd == "Q":
            ops.append(".quad(" + ", ".join(num(v) for v in a) + ")")
            cx, cy = a[2], a[3]
        elif cmd == "C":
            ops.append(".cubic(" + ", ".join(num(v) for v in a) + ")")
            cx, cy = a[4], a[5]
        elif cmd == "A":
            for c in arc_to_cubics(cx, cy, a[0], a[1], a[2], a[3] != 0, a[4] != 0, a[5], a[6]):
                ops.append(".cubic(" + ", ".join(num(v) for v in c) + ")")
            cx, cy = a[5], a[6]
        elif cmd == "Z":
            ops.append(".close")
            cx, cy = sx, sy
    stats["ops"] += len(ops)
    return ops


def swift_name(slug):
    head, *rest = slug.split("-")
    return head + "".join(p.capitalize() for p in rest)


def swift_array(name, ops):
    lines = [f"    static let {name}: [MusclePathOp] = ["]
    for i in range(0, len(ops), 4):
        lines.append("        " + ", ".join(ops[i:i + 4]) + ",")
    lines.append("    ]")
    return "\n".join(lines)


def main():
    data = json.loads(SRC.read_text())
    vb = data["viewBox"]
    base, muscles = data["base"], data["muscles"]
    assert len(base) == 12, len(base)
    assert len(muscles) == 17, len(muscles)

    header = "\n".join(("// " + line).rstrip() for line in MIT.strip().splitlines())
    parts = [
        "// Muscle map paths derived from react-native-body-highlighter by ELABBASSI Hicham",
        "// (github.com/HichamELBSI/react-native-body-highlighter), used under the MIT License:",
        "//",
        header,
        "//",
        "// Generated by scripts/gen-muscle-map.py from briefs/assets/muscle-map-paths.json. Do not edit.",
        "",
        "import CoreGraphics",
        "",
        "/// One absolute path command in viewBox units; arcs were converted to cubics by the generator.",
        "enum MusclePathOp: Sendable, Equatable {",
        "    case move(CGFloat, CGFloat), line(CGFloat, CGFloat)",
        "    case quad(CGFloat, CGFloat, CGFloat, CGFloat)",
        "    case cubic(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)",
        "    case close",
        "}",
        "",
        "enum MuscleMapPaths {",
        f"    static let viewBox = CGRect(x: {vb[0]}, y: {vb[1]}, width: {vb[2]}, height: {vb[3]})",
        "",
    ]
    for i, d in enumerate(base):
        parts.append(swift_array(f"base{i}", ops_for(d)))
    for slug in muscles:
        parts.append(swift_array(swift_name(slug), ops_for(muscles[slug])))
    parts.append("")
    parts.append("    static let base: [[MusclePathOp]] = [" + ", ".join(f"base{i}" for i in range(len(base))) + "]")
    parts.append("")
    parts.append("    /// Keyed by the JSON's hyphen slug (`Muscle.rawValue`).")
    parts.append("    static let muscles: [String: [MusclePathOp]] = [")
    for slug in muscles:
        parts.append(f'        "{slug}": {swift_name(slug)},')
    parts.append("    ]")
    parts.append("}")
    OUT.write_text("\n".join(parts) + "\n")

    # Spec 30 counts 176 `A` letters; one carries an implicit repeat, so 177 arcs.
    letters = sum(d.count("A") for d in base + list(muscles.values()))
    assert letters == 176, letters
    print(f"wrote {OUT.relative_to(ROOT)}")
    print(f"A commands {letters}, arcs {stats['arcs']} (degenerate skipped {stats['degenerate']}), "
          f"arc cubics {stats['arc_cubics']}, ops {stats['ops']}")
    for slug, d in muscles.items():
        print(f"  {slug}: {d.count('M')} subpaths")


if __name__ == "__main__":
    main()
