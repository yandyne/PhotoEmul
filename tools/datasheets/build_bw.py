"""Build a black-and-white negative profile from datasheet curves.

The profile keeps the colour profile layout (three channels) with identical
channels and channel_model "bw":
  - log_sensitivity: the datasheet spectral sensitivity in all three channels,
    held flat past the short end, continued down the measured slope past the
    long end, and scaled so an 18% grey under the reference illuminant gives the
    same exposure as the structural base's green channel;
  - density_curves: the datasheet characteristic curve minus base+fog, with
    log exposure 0 at the grey exposure of a meter-exposed frame,
    H = q K / S = 8.1 / ISO lux s, flat toe below the trace and a slowly
    flattening straight line past it; fitted with the cdfs model;
  - channel_density: spectrally flat silver, 1/3 per channel, so the three
    identical channel densities add up to the neutral density;
  - base_density / midscale_neutral_density: flat (base+fog, and grey on top).
The hanatos2025 adaptation data and print filter entries are the base's
(placeholders; the filters can be refitted with fit_bw_filters.py).

Usage:
  python build_bw.py NEW "Display Name" ISO DC_CSV LS_CSV "note"
        [--base kodak_portra_400] [--relative-x] [--linear-sensitivity]
        [--tail CSV] [--out DIR]
--relative-x: DC_CSV x is relative log exposure; it is anchored at the ISO speed
point (density 0.1 over base+fog at log H = log10(0.8 / ISO)).
--linear-sensitivity: LS_CSV y is linear relative sensitivity (log10 is taken).
--tail: extra spectral points (steep long-wavelength edge) merged into LS_CSV.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import colour
import numpy as np
from scipy.optimize import least_squares
from scipy.special import ndtr

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_positive import FILTER_FILES, OFX, PROFILE_DIRS, PY, csv, resample, smooth  # noqa: E402

GREY_H = 8.125  # q K = 0.65 * 12.5: grey exposure H = GREY_H / ISO lux s
SPEED_H = 0.8   # ISO speed point: density 0.1 over base+fog at H = SPEED_H / ISO


def fit_cdfs(le: np.ndarray, curve: np.ndarray, init: dict, c: int = 1) -> tuple[np.ndarray, ...]:
    """Three rising normal-cdf layers (the spektrafilm 'cdfs' model), started from
    the base's channel c (green by default); bounds are wide because silver curves are long."""
    p0 = np.concatenate([init["centers"][c], init["amplitudes"][c], init["sigmas"][c]])

    def model(p):
        ctr, amp, sig = p[:3], p[3:6], p[6:]
        return (amp * ndtr((le[:, None] - ctr) / sig)).sum(axis=1)

    lo = np.concatenate([np.full(3, le[0] - 1.0), np.full(3, 0.01), np.full(3, 0.05)])
    hi = np.concatenate([np.full(3, le[-1] + 1.0), np.full(3, 5.0), np.full(3, 3.0)])
    r = least_squares(lambda p: model(p) - curve, p0, bounds=(lo, hi))
    ctr, amp, sig = r.x[:3], r.x[3:6], r.x[6:]
    return ctr, amp, sig, amp * ndtr((le[:, None] - ctr) / sig)


def characteristic(dc: np.ndarray, iso: float, relative_x: bool, le: np.ndarray) -> tuple[np.ndarray, float]:
    fog = float(dc[:, 1].min())
    x, d = dc[:, 0], np.maximum(dc[:, 1] - fog, 0.0)
    if relative_x:
        x_speed = float(np.interp(0.1, np.maximum.accumulate(d), x))
        x = x - x_speed + np.log10(SPEED_H / iso)
    pts = np.column_stack([x - np.log10(GREY_H / iso), d])
    curve = resample(pts, le, 0.02)
    ok = np.flatnonzero(np.isfinite(curve))
    i0, i1 = ok[0], ok[-1]
    curve[ok] = smooth(curve[ok], 1.5)
    curve[:i0] = curve[i0]
    # past the trace: the end slope, flattening with a 1 logE time constant
    n = max(8, int(0.2 / (le[1] - le[0])))
    slope = max(np.polyfit(le[i1 - n:i1 + 1], curve[i1 - n:i1 + 1], 1)[0], 0.0)
    t = le[i1:] - le[i1]
    curve[i1:] = curve[i1] + slope * (1.0 - np.exp(-t))
    curve = np.maximum.accumulate(np.maximum(curve - curve[0], 0.0))
    return curve, fog


def sensitivity(ls: np.ndarray, wl: np.ndarray, linear: bool) -> np.ndarray:
    if linear:
        ls = ls[ls[:, 1] > 0]
        ls = np.column_stack([ls[:, 0], np.log10(ls[:, 1])])
    fine = np.arange(wl[0], wl[-1] + 0.5, 1.0)
    out = resample(ls, fine, 1.0)
    ok = np.flatnonzero(np.isfinite(out))
    i0, i1 = ok[0], ok[-1]
    out[ok] = smooth(out[ok], 2.0)
    out[:i0] = out[i0]
    # long side: the last 8 nm slope (at least 0.05/nm), floored 6 decades down
    slope = min(np.polyfit(fine[i1 - 8:i1 + 1], out[i1 - 8:i1 + 1], 1)[0], -0.05)
    out[i1:] = np.maximum(out[i1] + slope * (fine[i1:] - fine[i1]), np.nanmax(out) - 6.0)
    return np.interp(wl, fine, out)


def build(a: argparse.Namespace) -> None:
    release = json.loads((OFX / "profiles" / f"{a.base}.json").read_text())
    pyprof = json.loads((PY / "profiles" / f"{a.base}.json").read_text())
    d = release["data"]
    le = np.asarray(d["log_exposure"], float)
    wl = np.asarray(d["wavelengths"], float)

    curve, fog = characteristic(csv(Path(a.dc)), a.iso, a.relative_x, le)
    ctr, amp, sig, layers1 = fit_cdfs(le, curve, pyprof["data"]["density_curves_model"])
    fitted1 = layers1.sum(axis=1)
    d0 = float(np.interp(0.0, le, curve))
    print(f"fog {fog:.3f}, D over fog at grey {d0:.3f}, at +1 {np.interp(1.0, le, curve):.3f}, "
          f"at +2 {np.interp(2.0, le, curve):.3f}, max {curve.max():.2f}; "
          f"cdfs rms {np.sqrt(np.mean((fitted1 - curve) ** 2)):.4f}")

    ls_pts = csv(Path(a.ls))
    if a.tail:
        tail = csv(Path(a.tail))
        ls_pts = np.vstack([ls_pts[ls_pts[:, 0] < tail[0, 0]], tail])
    ls1 = sensitivity(ls_pts, wl, a.linear_sensitivity)
    illum = colour.SDS_ILLUMINANTS[release["info"]["reference_illuminant"]].copy().align(
        colour.SpectralShape(wl[0], wl[-1], wl[1] - wl[0])).values
    target = np.nansum(illum * 0.184 * 10 ** np.asarray(d["log_sensitivity"], float)[:, 1])
    ls1 += np.log10(target / np.nansum(illum * 0.184 * 10 ** ls1))
    print("log sensitivity " + ", ".join(f"{w:.0f}:{v:.2f}" for w, v in zip(wl[::8], ls1[::8])))

    three = lambda v: np.repeat(np.asarray(v, float)[..., None], 3, axis=-1)
    layers = np.repeat(layers1[:, :, None], 3, axis=2)
    model_out = {"model_type": "cdfs", "centers": [ctr.tolist()] * 3,
                 "amplitudes": [amp.tolist()] * 3, "sigmas": [sig.tolist()] * 3}
    flat = np.full(wl.size, fog)
    derivation = (f"Derived by PhotoEmul from {a.base} (structure only): {a.note} Black-and-white "
                  f"profile with three identical channels: characteristic curve and spectral sensitivity "
                  f"digitized from the manufacturer datasheet (base+fog {fog:.2f} removed, log exposure 0 "
                  f"at H = 8.1/ISO with ISO {a.iso:g}); spectrally flat silver density; "
                  f"hanatos2025 adaptation data are the base's.")
    for directory in PROFILE_DIRS:
        p = json.loads((directory / f"{a.base}.json").read_text())
        p["info"].update(stock=a.stock, name=a.name, channel_model="bw")
        if "fitted_cmy_midscale_neutral_density" in p["info"]:
            p["info"]["fitted_cmy_midscale_neutral_density"] = [d0] * 3
        pd = p["data"]
        pd["log_sensitivity"] = three(ls1).tolist()
        pd["channel_density"] = np.full((wl.size, 3), 1.0 / 3.0).tolist()
        pd["base_density"] = flat.tolist()
        pd["midscale_neutral_density"] = (flat + d0).tolist()
        pd["density_curves_layers"] = layers.tolist()
        if "density_curves_model" in pd:
            pd["density_curves"] = three(fitted1).tolist()
            pd["density_curves_model"] = model_out
        else:
            pd["density_curves"] = three(curve).tolist()
        p.setdefault("metadata", {})["derivation"] = derivation
        (directory / f"{a.stock}.json").write_text(json.dumps(p, indent=4))
    for f in FILTER_FILES:
        filters = json.loads(f.read_text())
        for paper in filters.values():
            for table in paper.values():
                if a.base in table:
                    table.setdefault(a.stock, table[a.base])
        f.write_text(json.dumps(filters, indent=4))
    if a.out:
        np.savez(Path(a.out) / f"{a.stock}_build.npz", le=le, curve=curve, fitted=fitted1, wl=wl, ls=ls1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    for name in ("stock", "name"):
        ap.add_argument(name)
    ap.add_argument("iso", type=float)
    for name in ("dc", "ls", "note"):
        ap.add_argument(name)
    ap.add_argument("--base", default="kodak_portra_400")
    ap.add_argument("--relative-x", action="store_true")
    ap.add_argument("--linear-sensitivity", action="store_true")
    ap.add_argument("--tail")
    ap.add_argument("--out")
    build(ap.parse_args())
