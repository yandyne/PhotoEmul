"""Build a colour print film profile from datasheet curves on a calibrated base print.

  - density_curves: the datasheet Status A characteristic curves minus each
    channel's minimum, unmixed to dye amounts with the base dyes (Status A is
    approximated by narrow gaussians at 615 / 540 / 445 nm), held flat past the
    traced range and shifted per channel so dye amount 1.0 is reached at the base
    channel's log exposure (datasheets often shift curves apart to keep them from
    overlapping, so the published positions carry no balance); fitted with the
    cdfs model per channel;
  - log_sensitivity, channel_density (dyes), base_density and the (empty)
    adaptation data are the base's;
  - print filter entries: every negative's entry for the base paper is copied to
    the new paper (refit them with fit_bw_filters.py --paper NEW --like BASE).

Usage:
  python build_print.py NEW "Display Name" DIGI_DIR "note" [--base kodak_2383]
DIGI_DIR holds density_curve_{r,g,b}.csv (x log H, y Status A density).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_bw import fit_cdfs  # noqa: E402
from build_positive import FILTER_FILES, OFX, PROFILE_DIRS, PY, csv  # noqa: E402

CHANNELS = "rgb"
STATUS_A = [(615.0, 12.0), (540.0, 15.0), (445.0, 12.0)]


def status_a_matrix(wl: np.ndarray, dyes: np.ndarray) -> np.ndarray:
    """A[i, j]: Status A density i of a unit amount of dye j."""
    resp = np.stack([np.exp(-0.5 * ((wl - c) / s) ** 2) for c, s in STATUS_A], axis=1)
    a = np.zeros((3, 3))
    for j in range(3):
        t = 10 ** -np.nan_to_num(dyes[:, j])
        a[:, j] = -np.log10((resp * t[:, None]).sum(0) / resp.sum(0))
    return a


def first_crossing(le: np.ndarray, y: np.ndarray, level: float) -> float:
    i = int(np.argmax(y >= level))
    return float(np.interp(level, [y[i - 1], y[i]], [le[i - 1], le[i]]))


def build(a: argparse.Namespace) -> None:
    release = json.loads((OFX / "profiles" / f"{a.base}.json").read_text())
    pyprof = json.loads((PY / "profiles" / f"{a.base}.json").read_text())
    d = release["data"]
    le = np.asarray(d["log_exposure"], float)
    wl = np.asarray(d["wavelengths"], float)
    dyes = np.asarray(d["channel_density"], float)
    base_dc = np.nan_to_num(np.asarray(d["density_curves"], float))
    target = np.array([first_crossing(le, base_dc[:, c], 1.0) for c in range(3)])
    unmix = np.linalg.inv(status_a_matrix(wl, dyes))

    raw = [csv(Path(a.digi) / f"density_curve_{c}.csv") for c in CHANNELS]
    dmin = np.array([r[:, 1].min() for r in raw])
    traced = [np.maximum.accumulate(r[:, 1] - r[:, 1].min()) for r in raw]
    shift = np.array([target[c] - np.interp(1.0, traced[c], raw[c][:, 0]) for c in range(3)])
    for _ in range(4):  # unmixing moves the dye-1.0 points a little; iterate the shifts
        status_a = np.stack([np.interp(le - shift[c], raw[c][:, 0], traced[c]) for c in range(3)], axis=1)
        dc = np.maximum.accumulate(np.maximum(status_a @ unmix.T, 0.0), axis=0)
        shift += target - np.array([first_crossing(le, dc[:, c], 1.0) for c in range(3)])

    init = pyprof["data"]["density_curves_model"]
    fits = [fit_cdfs(le, dc[:, c], init, c) for c in range(3)]
    fitted = np.stack([f[3].sum(axis=1) for f in fits], axis=1)
    layers = np.stack([f[3] for f in fits], axis=2)
    grad = [1.5 / (np.interp(2.0, dc[:, c], le) - np.interp(0.5, dc[:, c], le)) for c in range(3)]
    print(f"Status A minimum {np.round(dmin, 3)}, max dye {np.round(dc.max(0), 2)} "
          f"(base {np.round(base_dc.max(0), 2)}), dye gradient 0.5..2 {np.round(grad, 2)}, "
          f"le at dye 1.0 {np.round(target, 3)}; cdfs rms "
          + ", ".join(f"{np.sqrt(np.mean((fitted[:, c] - dc[:, c]) ** 2)):.4f}" for c in range(3)))

    model_out = {"model_type": "cdfs", "centers": [f[0].tolist() for f in fits],
                 "amplitudes": [f[1].tolist() for f in fits], "sigmas": [f[2].tolist() for f in fits]}
    derivation = (f"Derived by PhotoEmul from {a.base} (dyes, spectral sensitivity, base density): {a.note} "
                  f"Characteristic curves digitized from the manufacturer datasheet (Status A, unmixed with "
                  f"the base dyes; each channel placed so dye amount 1.0 falls at the base's exposure).")
    for directory in PROFILE_DIRS:
        p = json.loads((directory / f"{a.base}.json").read_text())
        p["info"].update(stock=a.stock, name=a.name)
        pd = p["data"]
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
        if a.base in filters:
            filters[a.stock] = json.loads(json.dumps(filters[a.base]))
        f.write_text(json.dumps(filters, indent=4))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    for name in ("stock", "name", "digi", "note"):
        ap.add_argument(name)
    ap.add_argument("--base", default="kodak_2383")
    build(ap.parse_args())
