"""List or export the vector paths of a datasheet graph (PDF pages drawn as vectors).

  python vector_paths.py list PDF PAGE x0 y0 x1 y1
      prints every stroked path inside the clip box (points, PDF units, y down)
      plus the text spans there, to find curves and axis tick labels.
  python vector_paths.py export SPEC.json OUT_DIR
      SPEC: {"pdf": ..., "page": n, "box": [x0, y0, x1, y1],
             "x_axis": [[pt, value], [pt, value]], "y_axis": [[pt, value], [pt, value]],
             "curves": {"name": [path index, ...]}}
      writes OUT_DIR/name.csv ("x, y" in axis units, sorted by x).

Path indices are the ones printed by "list" for the same box. Bezier segments are
sampled at 8 points; dashed curves come as one path with a dash pattern.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pymupdf


def paths(pdf: str, page: int, box: list[float]) -> list[dict]:
    clip = pymupdf.Rect(*box)
    out = []
    for d in pymupdf.open(pdf)[page].get_drawings():
        if not d["rect"].intersects(clip) or d.get("color") is None:
            continue
        pts: list[tuple[float, float]] = []
        for item in d["items"]:
            if item[0] == "l":
                pts += [(item[1].x, item[1].y), (item[2].x, item[2].y)]
            elif item[0] == "c":
                p0, p1, p2, p3 = (np.array([q.x, q.y]) for q in item[1:5])
                for t in np.linspace(0, 1, 8):
                    pts.append(tuple((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3))
            elif item[0] == "re":
                r = item[1]
                pts += [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
        pts = [p for p in pts if clip.contains(pymupdf.Point(*p))]
        if len(pts) >= 2:
            out.append({"pts": pts, "width": d.get("width"), "dashes": d.get("dashes"), "color": d.get("color")})
    return out


def list_box(pdf: str, page: int, box: list[float]) -> None:
    for i, p in enumerate(paths(pdf, page, box)):
        a = np.asarray(p["pts"])
        print(f"{i:3d} n={len(a):4d} x {a[:, 0].min():7.1f}..{a[:, 0].max():7.1f} y {a[:, 1].min():7.1f}..{a[:, 1].max():7.1f} "
              f"w={p['width']} dash={p['dashes']} col={p['color']}")
    for b in pymupdf.open(pdf)[page].get_text("dict", clip=pymupdf.Rect(*box))["blocks"]:
        for line in b.get("lines", []):
            for s in line["spans"]:
                x0, y0, x1, y1 = s["bbox"]
                print(f"text {s['text']!r} at x {0.5 * (x0 + x1):.1f} y {0.5 * (y0 + y1):.1f}")


def export(spec_path: str, out_dir: str) -> None:
    spec = json.loads(Path(spec_path).read_text())
    found = paths(spec["pdf"], spec["page"], spec["box"])
    (px0, vx0), (px1, vx1) = spec["x_axis"]
    (py0, vy0), (py1, vy1) = spec["y_axis"]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, idx in spec["curves"].items():
        a = np.concatenate([np.asarray(found[i]["pts"]) for i in idx])
        x = vx0 + (a[:, 0] - px0) * (vx1 - vx0) / (px1 - px0)
        y = vy0 + (a[:, 1] - py0) * (vy1 - vy0) / (py1 - py0)
        v = np.column_stack([x, y])
        v = v[np.argsort(v[:, 0], kind="stable")]
        np.savetxt(out / f"{name}.csv", v, delimiter=", ", fmt="%.6g")
        print(f"{name}: {len(v)} pts, x {v[0, 0]:.3g}..{v[-1, 0]:.3g}, y {v[:, 1].min():.3g}..{v[:, 1].max():.3g}")


if __name__ == "__main__":
    if sys.argv[1] == "list":
        list_box(sys.argv[2], int(sys.argv[3]), [float(v) for v in sys.argv[4:8]])
    else:
        export(sys.argv[2], sys.argv[3])
