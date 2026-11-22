"""Trace curves from a raster datasheet graph.

The axes are calibrated from two pixel/value pairs per axis (grid line positions).
Grid lines are erased, then each curve is followed column by column from a seed
point, picking the dark run closest to a linear prediction from the last points.
Output CSVs use the same "x, y" layout as the upstream raw datasheet data.

Spec (JSON):
{
  "image": "page.png",
  "box": [x0, y0, x1, y1],                 # plot area in pixels (inside the frame)
  "x_axis": [[px, value], [px, value]],
  "y_axis": [[py, value], [py, value]],
  "grid_x": [px, ...], "grid_y": [py, ...], # lines to erase
  "mask": [[x0, y0, x1, y1], ...],         # text/legend areas to ignore
  "curves": {"name": {"seed": [px, py], "until": px, "back": px, "tol": 6},
             "band": {"region": [x0, y0, x1, y1], "by": "rows" | "cols"}}
}
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load_dark(spec: dict, base: Path) -> np.ndarray:
    img = np.asarray(Image.open(base / spec["image"]).convert("L"), dtype=float)
    dark = img < spec.get("threshold", 140)
    for px in spec.get("grid_x", []):
        dark[:, int(round(px)) - 1:int(round(px)) + 2] = False
    for py in spec.get("grid_y", []):
        dark[int(round(py)) - 1:int(round(py)) + 2, :] = False
    for x0, y0, x1, y1 in spec.get("mask", []):
        dark[y0:y1, x0:x1] = False
    x0, y0, x1, y1 = spec["box"]
    keep = np.zeros_like(dark)
    keep[y0:y1, x0:x1] = True
    return dark & keep


def runs(column: np.ndarray) -> list[float]:
    idx = np.flatnonzero(column)
    if idx.size == 0:
        return []
    splits = np.flatnonzero(np.diff(idx) > 1) + 1
    return [float(g.mean()) for g in np.split(idx, splits)]


def trace(dark: np.ndarray, seed: tuple[float, float], until: int, tol: float = 6, gap: int = 25) -> list[tuple[int, float]]:
    x, y = int(seed[0]), float(seed[1])
    step = 1 if until > x else -1
    pts: list[tuple[int, float]] = []
    missed = 0
    while x != until:
        if len(pts) >= 4:
            (xa, ya), (xb, yb) = pts[-4], pts[-1]
            pred = yb + (yb - ya) / (xb - xa) * (x - xb)
        else:
            pred = pts[-1][1] if pts else y
        cands = runs(dark[:, x])
        best = min(cands, key=lambda c: abs(c - pred), default=None)
        if best is not None and abs(best - pred) <= tol + missed * 1.5:
            pts.append((x, best))
            missed = 0
        else:
            missed += 1
            if missed > gap:
                break
        x += step
    return sorted(pts)


def mean_line(dark: np.ndarray, region: list[int], by: str) -> list[tuple[float, float]]:
    """Centre of all dark pixels per row ("rows", for steep parts) or per column ("cols")
    inside region [x0, y0, x1, y1]; used where several curves overlap into one band."""
    x0, y0, x1, y1 = region
    pts = []
    if by == "rows":
        for y in range(y0, y1):
            xs = np.flatnonzero(dark[y, x0:x1])
            if xs.size:
                pts.append((x0 + xs.mean(), float(y)))
    else:
        for x in range(x0, x1):
            ys = np.flatnonzero(dark[y0:y1, x])
            if ys.size:
                pts.append((float(x), y0 + ys.mean()))
    return sorted(pts)


def to_values(spec: dict, pts: list[tuple[int, float]]) -> np.ndarray:
    (px0, vx0), (px1, vx1) = spec["x_axis"]
    (py0, vy0), (py1, vy1) = spec["y_axis"]
    p = np.asarray(pts, dtype=float)
    xs = vx0 + (p[:, 0] - px0) * (vx1 - vx0) / (px1 - px0)
    ys = vy0 + (p[:, 1] - py0) * (vy1 - vy0) / (py1 - py0)
    return np.column_stack([xs, ys])


def main(spec_path: str, out_dir: str) -> None:
    spec_file = Path(spec_path)
    spec = json.loads(spec_file.read_text())
    base = Path(spec.get("image_dir", spec_file.parent))
    dark = load_dark(spec, base)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    overlay = np.stack([np.where(dark, 0, 255)] * 3, axis=-1).astype(np.uint8)
    colours = [(230, 30, 30), (30, 170, 30), (30, 60, 230), (200, 120, 0), (150, 0, 150), (0, 150, 150)]
    for i, (name, c) in enumerate(spec["curves"].items()):
        if "region" in c:
            pts = mean_line(dark, c["region"], c.get("by", "cols"))
        else:
            pts = trace(dark, c["seed"], c["until"], c.get("tol", 6), c.get("gap", 25))
        if "back" in c:
            pts = sorted(set(pts) | set(trace(dark, c["seed"], c["back"], c.get("tol", 6), c.get("gap", 25))))
        for px, py in pts:
            overlay[int(round(py)) - 1:int(round(py)) + 2, int(round(px))] = colours[i % len(colours)]
        values = to_values(spec, pts)
        np.savetxt(out / f"{name}.csv", values, delimiter=", ", fmt="%.6g")
        print(f"{name}: {len(pts)} pts, x {values[0, 0]:.3g}..{values[-1, 0]:.3g}, y {values[:, 1].min():.3g}..{values[:, 1].max():.3g}")
    x0, y0, x1, y1 = spec["box"]
    Image.fromarray(overlay[y0:y1, x0:x1]).save(out / f"{spec_file.stem}_overlay.png")


if __name__ == "__main__":
    main(*sys.argv[1:3])
