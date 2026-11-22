"""Build an instant (diffusion-transfer) film profile from datasheet curves on a
calibrated reversal base profile.

Instant prints are reflection prints; they are approximated as a positive film
scanned directly (the reflection densities are read as transmission densities):
  - density_curves: the datasheet characteristic curves (reflection density, Status
    A-like) minus each channel's minimum, unmixed to dye amounts with the base dyes
    (Status A approximated by narrow gaussians at 615 / 545 / 445 nm), placed so the
    green curve crosses the reversal midscale density at the base's log exposure,
    held flat past both traced ends and fitted with the falling cdfs model;
  - log_sensitivity: the datasheet spectral sensitivity (log10 relative sensitivity,
    higher = more sensitive), both flanks continued down the measured slope, each
    channel scaled so an 18% grey under the reference illuminant gives the base
    channel's exposure;
  - base_density: the tint of the datasheet minimum densities (print white) on top
    of the base film's own minimum (the eye adapts to the paper white), unmixed and
    spread with the base dyes;
  - channel_density (dyes) and the hanatos2025 adaptation data are the base's.

Usage:
  python build_instant.py NEW "Display Name" DIGI_DIR "note" [--base fujifilm_provia_100f]
DIGI_DIR holds density_curve_{r,g,b}.csv (x log exposure, any origin; y density)
and log_sensitivity_{r,g,b}.csv (x nm, y log10 relative sensitivity).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import colour
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_positive import (FILTER_FILES, GREY_DENSITY, OFX, PROFILE_DIRS, PY, csv, fit_cdfs,  # noqa: E402
                            resample, smooth)

CHANNELS = "rgb"  # profile channel order: red-sensitive (cyan dye) first
STATUS_A = [(615.0, 12.0), (545.0, 12.0), (445.0, 12.0)]


def status_a_matrix(wl: np.ndarray, dyes: np.ndarray) -> np.ndarray:
    """A[i, j]: Status A density i of a unit amount of dye j."""
    resp = np.stack([np.exp(-0.5 * ((wl - c) / s) ** 2) for c, s in STATUS_A], axis=1)
    a = np.zeros((3, 3))
    for j in range(3):
        t = 10 ** -np.nan_to_num(dyes[:, j])
        a[:, j] = -np.log10((resp * t[:, None]).sum(0) / resp.sum(0))
    return a


def curves(digi: Path, le: np.ndarray, le_grey: float) -> tuple[np.ndarray, np.ndarray]:
    raw = [csv(digi / f"density_curve_{c}.csv") for c in CHANNELS]
    dmin = np.array([dc[:, 1].min() for dc in raw])
    g = raw[1]
    d = np.minimum.accumulate(g[:, 1] - dmin[1])
    x_grey = float(np.interp(GREY_DENSITY, d[::-1], g[::-1, 0]))
    out = []
    for dc, m in zip(raw, dmin):
        pts = np.column_stack([dc[:, 0] - x_grey + le_grey, dc[:, 1] - m])
        curve = resample(pts, le, 0.02)
        ok = np.flatnonzero(np.isfinite(curve))
        curve[ok] = smooth(curve[ok], 1.5)
        curve = np.interp(le, le[ok], curve[ok])  # hold both traced ends
        out.append(np.maximum(np.minimum.accumulate(curve), 0.0))
    return np.stack(out, axis=1), dmin


def sensitivity(pts: np.ndarray, wl: np.ndarray) -> np.ndarray:
    fine = np.arange(wl[0], wl[-1] + 0.5, 1.0)
    out = resample(pts, fine, 1.0)
    ok = np.flatnonzero(np.isfinite(out))
    i0, i1 = ok[0], ok[-1]
    out[ok] = smooth(out[ok], 2.0)
    floor = np.nanmax(out) - 6.0
    # both flanks: the last 8 nm slope (at least 0.03/nm), floored 6 decades down
    s0 = max(np.polyfit(fine[i0:i0 + 9], out[i0:i0 + 9], 1)[0], 0.03)
    s1 = min(np.polyfit(fine[i1 - 8:i1 + 1], out[i1 - 8:i1 + 1], 1)[0], -0.03)
    out[:i0] = np.maximum(out[i0] - s0 * (fine[i0] - fine[:i0]), floor)
    out[i1:] = np.maximum(out[i1] + s1 * (fine[i1:] - fine[i1]), floor)
    return np.interp(wl, fine, out)


def build(a: argparse.Namespace) -> None:
    release = json.loads((OFX / "profiles" / f"{a.base}.json").read_text())
    pyprof = json.loads((PY / "profiles" / f"{a.base}.json").read_text())
    d = release["data"]
    le = np.asarray(d["log_exposure"], float)
    wl = np.asarray(d["wavelengths"], float)
    dyes = np.asarray(d["channel_density"], float)
    digi = Path(a.digi)

    base_dc = np.asarray(d["density_curves"], float)
    base_g = base_dc[:, 1] - np.nanmin(base_dc[:, 1])
    le_grey = float(np.interp(GREY_DENSITY, base_g[::-1], le[::-1]))
    status_a, dmin = curves(digi, le, le_grey)
    unmix = np.linalg.inv(status_a_matrix(wl, dyes))
    dc = np.minimum.accumulate(np.maximum(status_a @ unmix.T, 0.0), axis=0)
    i0 = int(np.argmin(np.abs(le)))
    model = pyprof["data"]["density_curves_model"]
    fits = [fit_cdfs(le, dc[:, c], model, c) for c in range(3)]
    layers = np.stack([f[3] for f in fits], axis=2)  # (log exposure, layer, channel)
    fitted = layers.sum(axis=1)
    d0 = fitted[i0]
    print(f"density minimum {np.round(dmin, 3)}, Dmax over min {np.round(status_a.max(axis=0), 2)}, "
          f"dye amount at le 0 {np.round(d0, 3)}, grey at le {le_grey:+.2f}; cdfs rms "
          + ", ".join(f"{np.sqrt(np.mean((fitted[:, c] - dc[:, c]) ** 2)):.4f}" for c in range(3)))

    illum = colour.SDS_ILLUMINANTS[release["info"]["reference_illuminant"]].copy().align(
        colour.SpectralShape(wl[0], wl[-1], wl[1] - wl[0])).values
    base_ls = np.asarray(d["log_sensitivity"], float)
    ls = np.zeros_like(base_ls)
    for c, name in enumerate(CHANNELS):
        s = sensitivity(csv(digi / f"log_sensitivity_{name}.csv"), wl)
        target = np.nansum(illum * 0.184 * 10 ** base_ls[:, c])
        ls[:, c] = s + np.log10(target / np.nansum(illum * 0.184 * 10 ** s))
        print(f"log sensitivity {name} peak {wl[np.argmax(ls[:, c])]:.0f} nm (base "
              f"{wl[np.nanargmax(base_ls[:, c])]:.0f}), "
              + ", ".join(f"{w:.0f}:{v:.2f}" for w, v in zip(wl[::8], ls[::8, c])))

    nan = np.isnan(np.asarray(d["base_density"], float))
    # print white: the eye adapts to the paper, so keep only the datasheet tint of the minimum
    # densities on top of the base film's own minimum
    resp = np.stack([np.exp(-0.5 * ((wl - c) / s) ** 2) for c, s in STATUS_A], axis=1)
    t = 10 ** -np.nan_to_num(np.asarray(d["base_density"], float))
    base_min = float((-np.log10((resp * t[:, None]).sum(0) / resp.sum(0))).min())
    white = dmin - dmin.min() + base_min
    base = np.nan_to_num(dyes) @ np.maximum(unmix @ white, 0.0)
    base[nan] = np.nan
    midscale = base + np.nan_to_num(dyes) @ d0
    model_out = {"model_type": "cdfs", "centers": [f[0].tolist() for f in fits],
                 "amplitudes": [f[1].tolist() for f in fits], "sigmas": [f[2].tolist() for f in fits]}
    derivation = (f"Derived by PhotoEmul from {a.base} (dyes and structure): {a.note} Instant print "
                  f"approximated as a directly scanned positive: characteristic curves (reflection "
                  f"density read as transmission density, unmixed with the base dyes) and spectral "
                  f"sensitivity digitized from the manufacturer datasheet; print "
                  f"white tint from the datasheet minimum densities; hanatos2025 adaptation data are the base's.")
    for directory in PROFILE_DIRS:
        p = json.loads((directory / f"{a.base}.json").read_text())
        p["info"].update(stock=a.stock, name=a.name)
        pd = p["data"]
        pd["log_sensitivity"] = ls.tolist()
        pd["base_density"] = [None if np.isnan(v) else v for v in base]
        pd["midscale_neutral_density"] = [None if np.isnan(v) else v for v in midscale]
        pd["density_curves_layers"] = layers.tolist()
        if "density_curves_model" in pd:
            pd["density_curves"] = fitted.tolist()
            pd["density_curves_model"] = model_out
        else:
            pd["density_curves"] = dc.tolist()
        p.setdefault("metadata", {})["derivation"] = derivation
        (directory / f"{a.stock}.json").write_text(json.dumps(p, indent=4))
    for f in FILTER_FILES:
        filters = json.loads(f.read_text())
        for paper in filters.values():
            for table in paper.values():
                if a.base in table:
                    table.setdefault(a.stock, table[a.base])
        f.write_text(json.dumps(filters, indent=4))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    for name in ("stock", "name", "digi", "note"):
        ap.add_argument(name)
    ap.add_argument("--base", default="fujifilm_provia_100f")
    build(ap.parse_args())
