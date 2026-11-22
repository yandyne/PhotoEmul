"""Build a colour negative profile from datasheet curves on a calibrated base profile.

  - density_curves: the datasheet Status M characteristic curves (relative log
    exposure) minus each channel's minimum, placed on the ISO 5800 speed point
    (H_M = sqrt(H_G H_slowest) at 0.15 over minimum, H_M = sqrt(2) / ISO; log
    exposure 0 at the grey exposure 8.1 / ISO lux s), extended as in build_bw and
    unmixed from Status M to dye amounts with the base dyes (Status M is
    approximated by narrow gaussians at 650 / 535 / 445 nm); fitted with the cdfs
    model per channel;
  - log_sensitivity: a wedge spectrogram (height k * log sensitivity under the
    spectrogram illuminant) with the illuminant divided out, both flanks continued
    down the measured slope, and each channel scaled so an 18% grey under the
    reference illuminant gives the base channel's exposure;
  - base_density: the datasheet minimum densities, unmixed to dye amounts and
    spread with the base dyes (no separate orange mask);
  - channel_density (dyes), the hanatos2025 adaptation data and print filter
    entries are the base's (refit the filters with fit_bw_filters.py).

Usage:
  python build_negative.py NEW "Display Name" ISO DIGI_DIR "note"
        [--base kodak_gold_200] [--spectrogram A] [--scale 0.5] [--keep-sensitivity] [--out DIR]
--keep-sensitivity keeps the base's log_sensitivity (no spectral data published).
DIGI_DIR holds density_curve_{r,g,b}.csv (x relative log exposure, y Status M
density) and log_sensitivity_{r,g,b}.csv (x nm, y spectrogram height).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import colour
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_bw import GREY_H, characteristic, fit_cdfs  # noqa: E402
from build_positive import FILTER_FILES, OFX, PROFILE_DIRS, PY, csv, resample, smooth  # noqa: E402

CHANNELS = "rgb"  # profile channel order: red-sensitive (cyan dye) first
STATUS_M = [(650.0, 12.0), (535.0, 15.0), (445.0, 12.0)]
SPEED_D = 0.15


def reference_sd(name: str) -> colour.SpectralDistribution:
    """A profile's reference illuminant; 'T' is colour's Incandescent source, as in spektrafilm."""
    return colour.SDS_LIGHT_SOURCES["Incandescent"] if name == "T" else colour.SDS_ILLUMINANTS[name]


def status_m_matrix(wl: np.ndarray, dyes: np.ndarray) -> np.ndarray:
    """A[i, j]: Status M density i of a unit amount of dye j."""
    resp = np.stack([np.exp(-0.5 * ((wl - c) / s) ** 2) for c, s in STATUS_M], axis=1)
    a = np.zeros((3, 3))
    for j in range(3):
        t = 10 ** -np.nan_to_num(dyes[:, j])
        a[:, j] = -np.log10((resp * t[:, None]).sum(0) / resp.sum(0))
    return a


def curves(digi: Path, iso: float, le: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    raw = [csv(digi / f"density_curve_{c}.csv") for c in CHANNELS]
    speed = []
    for dc in raw:
        d = np.maximum.accumulate(dc[:, 1] - dc[:, 1].min())
        speed.append(float(np.interp(SPEED_D, d, dc[:, 0])))
    x_m = 0.5 * (speed[1] + max(speed))
    shift = np.log10(np.sqrt(2.0) / iso) - x_m
    out, fog = [], []
    for dc in raw:
        curve, f = characteristic(np.column_stack([dc[:, 0] + shift, dc[:, 1]]), iso, False, le)
        out.append(curve)
        fog.append(f)
    print("speed points (le) " + ", ".join(f"{c}:{s + shift - np.log10(GREY_H / iso):.2f}"
                                          for c, s in zip(CHANNELS, speed)))
    return np.stack(out, axis=1), np.array(fog)


def spectrogram(pts: np.ndarray, wl: np.ndarray, illum: str, scale: float) -> np.ndarray:
    pts = pts[pts[:, 1] > 0.05]
    spd = colour.SDS_ILLUMINANTS[illum].copy().align(colour.SpectralShape(300, 830, 1))
    pts = np.column_stack([pts[:, 0], scale * pts[:, 1] - np.log10(spd[pts[:, 0]])])
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

    status_m, dmin = curves(digi, a.iso, le)
    unmix = np.linalg.inv(status_m_matrix(wl, dyes))
    dc = np.maximum.accumulate(np.maximum(status_m @ unmix.T, 0.0), axis=0)
    init = pyprof["data"]["density_curves_model"]
    fits = [fit_cdfs(le, dc[:, c], init, c) for c in range(3)]
    fitted = np.stack([f[3].sum(axis=1) for f in fits], axis=1)
    layers = np.stack([f[3] for f in fits], axis=2)  # (log exposure, layer, channel)
    i0 = int(np.argmin(np.abs(le)))
    d0 = dc[i0]
    gamma = (np.interp(1.0, le, dc.T[1]) - np.interp(-0.5, le, dc.T[1])) / 1.5
    print(f"Status M minimum {np.round(dmin, 3)}, dye amount at grey {np.round(d0, 3)}, "
          f"green gradient -0.5..+1 {gamma:.2f}; cdfs rms "
          + ", ".join(f"{np.sqrt(np.mean((fitted[:, c] - dc[:, c]) ** 2)):.4f}" for c in range(3)))

    illum = reference_sd(release["info"]["reference_illuminant"]).copy().align(
        colour.SpectralShape(wl[0], wl[-1], wl[1] - wl[0])).values
    base_ls = np.asarray(d["log_sensitivity"], float)
    ls = base_ls.copy() if a.keep_sensitivity else np.zeros_like(base_ls)
    for c, name in enumerate([] if a.keep_sensitivity else CHANNELS):
        s = spectrogram(csv(digi / f"log_sensitivity_{name}.csv"), wl, a.spectrogram, a.scale)
        target = np.nansum(illum * 0.184 * 10 ** base_ls[:, c])
        ls[:, c] = s + np.log10(target / np.nansum(illum * 0.184 * 10 ** s))
        print(f"log sensitivity {name} peak {wl[np.argmax(ls[:, c])]:.0f} nm, "
              + ", ".join(f"{w:.0f}:{v:.2f}" for w, v in zip(wl[::8], ls[::8, c])))

    nan = np.isnan(np.asarray(d["base_density"], float))
    base = np.nan_to_num(dyes) @ np.maximum(unmix @ dmin, 0.0)
    base[nan] = np.nan
    midscale = base + np.nan_to_num(dyes) @ d0
    model_out = {"model_type": "cdfs", "centers": [f[0].tolist() for f in fits],
                 "amplitudes": [f[1].tolist() for f in fits], "sigmas": [f[2].tolist() for f in fits]}
    spectral = (f"spectral sensitivity is the base's" if a.keep_sensitivity else
                f"wedge spectrogram to illuminant {a.spectrogram} read as {a.scale:g} log units per division")
    derivation = (f"Derived by PhotoEmul from {a.base} (dyes and structure): {a.note} Characteristic "
                  f"curves{'' if a.keep_sensitivity else ' and spectral sensitivity'} digitized from the "
                  f"manufacturer datasheet (Status M curves on the ISO {a.iso:g} speed point, unmixed with "
                  f"the base dyes; {spectral}); minimum density from the datasheet; hanatos2025 adaptation "
                  f"data are the base's.")
    for directory in PROFILE_DIRS:
        p = json.loads((directory / f"{a.base}.json").read_text())
        p["info"].update(stock=a.stock, name=a.name)
        if "fitted_cmy_midscale_neutral_density" in p["info"]:
            p["info"]["fitted_cmy_midscale_neutral_density"] = d0.tolist()
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
    if a.out:
        np.savez(Path(a.out) / f"{a.stock}_build.npz", le=le, status_m=status_m, dc=dc, fitted=fitted,
                 wl=wl, ls=ls, base_ls=base_ls, base=base)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    for name in ("stock", "name"):
        ap.add_argument(name)
    ap.add_argument("iso", type=float)
    for name in ("digi", "note"):
        ap.add_argument(name)
    ap.add_argument("--base", default="kodak_gold_200")
    ap.add_argument("--spectrogram", default="A")
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--keep-sensitivity", action="store_true")
    ap.add_argument("--out")
    build(ap.parse_args())
