"""Build a reversal (slide) film profile from digitized datasheet curves and a
calibrated base profile of the same family.

The release profiles were made from raw datasheet CSVs by a factory that is not
runnable any more. For the base stock the processed density curves turn out to be
a linear unmix of the raw Status A curves plus an exposure shift:

    processed(le) ~= M @ (raw(le + s) - min(raw))

M and s are fitted on the base, then applied to the new film's raw curves, so the
new profile goes through the same pipeline. Spectral sensitivity is the traced
curve on the base's raw->processed offset; past the traced range the short side keeps
the difference to the base and the steep long side is the base flank shifted in
wavelength to meet the trace. Each channel is then
re-balanced to give the base's exposure for an 18% grey under the reference
illuminant. Dyes, base density and the hanatos2025 adaptation data stay the base's.

Usage:
  python build_positive.py NEW BASE "Display Name" BASE_RAW_DIR NEW_DIGI_DIR "note"

NEW_DIGI_DIR holds density_curve_{r,g,b}.csv (channel shoulder traces),
density_curve_mid_steep.csv / density_curve_mid_toe.csv (the shared band where the
three curves overlap), log_sensitivity_{r,g,b}.csv and an optional build.json:
  {"split": 2.75, "blend": 0.25,          # shoulders -> band over split..split+blend D
   "sensitivity_ranges": {"r": [lo, hi]}}  # nm range clear of curve crossings
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import colour
import numpy as np
from scipy.optimize import least_squares
from scipy.special import ndtr

ROOT = Path(__file__).resolve().parents[2]
OFX = ROOT / "build/ofx/SpektraFilm/Resources/data"
PY = ROOT / "references/spektrafilm-main/src/spektrafilm/data"
PROFILE_DIRS = [OFX / "profiles", OFX / "profiles/archive", PY / "profiles"]
FILTER_FILES = [OFX / "filters/neutral_print_filters.json", PY / "filters/neutral_print_filters.json"]
GREY_DENSITY = np.log10(1 / 0.184)  # reversal midscale: green density over min at le = 0


def csv(path: Path) -> np.ndarray:
    a = np.loadtxt(path, delimiter=",", ndmin=2)
    return a[np.argsort(a[:, 0])]


def resample(points: np.ndarray, grid: np.ndarray, step: float = 0.02) -> np.ndarray:
    """Bin-median a traced point cloud onto grid (NaN outside the traced range)."""
    centres, values = [], []
    for x in np.arange(points[0, 0], points[-1, 0] + step, step):
        sel = points[(points[:, 0] >= x - step / 2) & (points[:, 0] < x + step / 2), 1]
        if sel.size:
            centres.append(x)
            values.append(np.median(sel))
    out = np.interp(grid, centres, values, left=np.nan, right=np.nan)
    return out


def smooth(y: np.ndarray, sigma: float = 2.0) -> np.ndarray:
    k = np.exp(-0.5 * (np.arange(-6, 7) / sigma) ** 2)
    k /= k.sum()
    pad = np.pad(y, 6, mode="edge")
    return np.convolve(pad, k, mode="valid")


def raw_curves(base_raw: Path) -> tuple[np.ndarray, np.ndarray]:
    curves = [csv(base_raw / f"density_curve_{c}.csv") for c in "rgb"]
    grid = np.linspace(max(c[0, 0] for c in curves), min(c[-1, 0] for c in curves), 300)
    return grid, np.stack([np.interp(grid, c[:, 0], c[:, 1]) for c in curves], axis=1)


def assemble_new(digi: Path, split: float, blend: float) -> tuple[np.ndarray, np.ndarray]:
    """Channel shoulders blended into the shared mid band over split..split + blend D."""
    steep, toe = csv(digi / "density_curve_mid_steep.csv"), csv(digi / "density_curve_mid_toe.csv")
    shoulders = [csv(digi / f"density_curve_{c}.csv") for c in "rgb"]
    lo = min(s[0, 0] for s in shoulders)
    grid = np.arange(lo, toe[-1, 0], 0.01)
    join = 0.5 * (steep[-1, 0] + toe[0, 0])
    mid = np.where(grid < join, resample(steep, grid), resample(toe, grid))
    ok = np.isfinite(mid)
    mid = np.interp(grid, grid[ok], np.minimum.accumulate(mid[ok]), left=np.nan)
    out = np.empty((grid.size, 3))
    for c, sh in enumerate(shoulders):
        top = resample(sh, grid)
        w = np.clip((np.nan_to_num(mid, nan=9.0) - split) / blend, 0, 1)
        w = np.where(np.isfinite(top), w, 0.0)
        curve = np.where(np.isfinite(mid), w * np.nan_to_num(top) + (1 - w) * mid, top)
        ok = np.isfinite(curve)
        curve = np.interp(grid, grid[ok], curve[ok])  # hold the traced ends
        out[:, c] = smooth(np.minimum.accumulate(curve), 2.0)
    return grid, out


def sample(grid: np.ndarray, curves: np.ndarray, x: np.ndarray) -> np.ndarray:
    return np.stack([np.interp(x, grid, curves[:, c]) for c in range(3)], axis=1)


def fit_map(le: np.ndarray, processed: np.ndarray, grid: np.ndarray, raw: np.ndarray):
    rel = raw - raw.min(axis=0)
    best = None
    for s in np.arange(-1.5, 0.5, 0.002):
        x = le + s
        sel = (x > grid[0]) & (x < grid[-1])
        a = sample(grid, rel, x[sel])
        m, *_ = np.linalg.lstsq(a, processed[sel], rcond=None)
        err = np.sqrt(np.mean((a @ m - processed[sel]) ** 2))
        if best is None or err < best[0]:
            best = (err, s, m.T)
    return best


def fit_cdfs(le: np.ndarray, curve: np.ndarray, init: dict, c: int) -> tuple[np.ndarray, ...]:
    """Three falling normal-cdf layers per channel, the spektrafilm 'cdfs' model."""
    p0 = np.concatenate([init["centers"][c], init["amplitudes"][c], init["sigmas"][c]])

    def model(p):
        ctr, amp, sig = p[:3], p[3:6], p[6:]
        return (amp * ndtr(-(le[:, None] - ctr) / sig)).sum(axis=1)

    lo = np.concatenate([p0[:3] - 1.5, np.full(3, 0.01), np.full(3, 0.05)])
    hi = np.concatenate([p0[:3] + 1.5, np.full(3, 5.0), np.full(3, 1.5)])
    r = least_squares(lambda p: model(p) - curve, p0, bounds=(lo, hi))
    ctr, amp, sig = r.x[:3], r.x[3:6], r.x[6:]
    return ctr, amp, sig, amp * ndtr(-(le[:, None] - ctr) / sig)


def build(stock: str, base: str, name: str, base_raw_dir: str, digi_dir: str, note: str) -> None:
    release = json.loads((OFX / "profiles" / f"{base}.json").read_text())
    pyprof = json.loads((PY / "profiles" / f"{base}.json").read_text())
    d = release["data"]
    le = np.asarray(d["log_exposure"], float)
    processed = np.asarray(d["density_curves"], float)
    processed = processed - np.nanmin(processed, axis=0)

    base_grid, base_raw = raw_curves(Path(base_raw_dir))
    err, s, m = fit_map(le, processed, base_grid, base_raw)
    print(f"base map: rms {err:.4f}, shift {s:.3f}\n{np.round(m, 3)}")

    cfg_file = Path(digi_dir) / "build.json"
    cfg = json.loads(cfg_file.read_text()) if cfg_file.exists() else {}
    grid, new_raw = assemble_new(Path(digi_dir), cfg.get("split", 2.75), cfg.get("blend", 0.25))
    new = sample(grid, new_raw - new_raw.min(axis=0), le + s) @ m.T
    new = np.maximum(new - new.min(axis=0), 0)
    # same midscale convention as the base: green crosses GREY_DENSITY at the same le
    def crossing(curve):
        return float(np.interp(GREY_DENSITY, curve[::-1, 1], le[::-1]))
    shift = crossing(new) - crossing(processed)
    new = sample(le, new, le + shift)
    print(f"midscale shift {shift:+.3f} logE, Dmax {np.round(new.max(axis=0), 2)} vs base {np.round(processed.max(axis=0), 2)}")

    model = pyprof["data"]["density_curves_model"]
    centers, amps, sigmas = np.zeros((3, 3)), np.zeros((3, 3)), np.zeros((3, 3))
    layers = np.zeros((le.size, 3, 3))
    for c in range(3):
        centers[c], amps[c], sigmas[c], layers[:, :, c] = fit_cdfs(le, new[:, c], model, c)
    fitted = layers.sum(axis=1)
    print(f"cdfs fit rms {np.sqrt(np.mean((fitted - new) ** 2)):.4f}")

    wl = np.asarray(d["wavelengths"], float)
    ls_base = np.asarray(d["log_sensitivity"], float)
    ls_new = ls_base.copy()
    illum = colour.SDS_ILLUMINANTS[release["info"]["reference_illuminant"]].copy().align(
        colour.SpectralShape(wl[0], wl[-1], wl[1] - wl[0])).values
    ranges = cfg.get("sensitivity_ranges", {})
    fine = np.arange(wl[0], wl[-1] + 0.5, 1.0)
    for c, ch in enumerate("rgb"):
        a, b = csv(Path(base_raw_dir) / f"log_sensitivity_{ch}.csv"), csv(Path(digi_dir) / f"log_sensitivity_{ch}.csv")
        lo, hi = ranges.get(ch, (b[0, 0], b[-1, 0]))
        b = b[(b[:, 0] >= lo) & (b[:, 0] <= hi)]
        # processed = raw + constant inside the raw range, so the traced curve maps the same way
        offset = np.nanmean(ls_base[:, c] - np.interp(wl, a[:, 0], a[:, 1], left=np.nan, right=np.nan))
        base_f = np.interp(fine, wl, ls_base[:, c])
        trace_f = resample(b, fine, 1.0) + offset
        ok = np.flatnonzero(np.isfinite(trace_f))
        i0, i1, top = ok[0], ok[-1], int(np.argmax(base_f))
        out = np.interp(fine, fine[ok], trace_f[ok])
        # short side (gentle flank): hold the difference to the base
        out[:i0] = base_f[:i0] + (out[i0] - base_f[i0])
        # long side (steep flank): the base flank moved sideways to meet the traced end
        # (matched relative to each curve's peak: a faster film sits higher overall)
        lift = out[i0:i1 + 1].max() - base_f[top]
        flank = np.minimum.accumulate(base_f[top:]) + lift
        w_hi = np.interp(out[i1], flank[::-1], fine[top:][::-1])
        if out[i1] > flank[0] - 0.5:  # trace ends near the peak: no usable edge position
            w_hi = fine[i1]
            flank += out[i1] - np.interp(fine[i1], fine[top:], flank)
        out[i1:] = np.interp(fine[i1:] - (fine[i1] - w_hi), fine[top:], flank)
        print(f"{ch}: traced {fine[i0]:.0f}..{fine[i1]:.0f} nm, long flank shifted {fine[i1] - w_hi:+.0f} nm")
        delta = smooth(out, 4) - base_f
        ls_new[:, c] = np.interp(wl, fine, base_f + delta)
        e_base = np.nansum(illum * 10 ** ls_base[:, c])
        e_new = np.nansum(illum * 10 ** ls_new[:, c])
        ls_new[:, c] += np.log10(e_base / e_new)
        peak = int(np.nanargmax(ls_base[:, c]))
        print(f"{ch}: peak {wl[peak]:.0f} -> {wl[int(np.nanargmax(ls_new[:, c]))]:.0f} nm, "
              f"delta range {delta.min():+.2f}..{delta.max():+.2f}")

    derivation = (f"Derived by PhotoEmul from {base}: {note} Density curves = base raw->processed map "
                  f"(rms {err:.3f}) applied to curves digitized from the datasheet; spectral sensitivity = "
                  f"datasheet curves with base-shaped flanks, grey-balanced under {release['info']['reference_illuminant']}; "
                  "dyes, base density and adaptation data are the base's.")
    model_out = {"model_type": "cdfs", "centers": centers.tolist(), "amplitudes": amps.tolist(), "sigmas": sigmas.tolist()}
    for directory in PROFILE_DIRS:
        p = json.loads((directory / f"{base}.json").read_text())
        p["info"].update(stock=stock, name=name)
        p["data"]["log_sensitivity"] = ls_new.tolist()
        p["data"]["density_curves_layers"] = layers.tolist()
        if "density_curves_model" in p["data"]:
            p["data"]["density_curves"] = fitted.tolist()
            p["data"]["density_curves_model"] = model_out
        else:
            p["data"]["density_curves"] = new.tolist()
        p.setdefault("metadata", {})["derivation"] = derivation
        (directory / f"{stock}.json").write_text(json.dumps(p, indent=4))
    for f in FILTER_FILES:
        filters = json.loads(f.read_text())
        for paper in filters.values():
            for table in paper.values():
                if base in table:
                    table[stock] = table[base]
        f.write_text(json.dumps(filters, indent=4))
    np.savez(Path(digi_dir) / f"{stock}_build.npz", le=le, base=processed, new=new, fitted=fitted,
             wl=wl, ls_base=ls_base, ls_new=ls_new)


if __name__ == "__main__":
    build(*sys.argv[1:7])
