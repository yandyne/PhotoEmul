"""Convert an upstream spektrafilm (dev branch) black-and-white profile to the
three-channel layout the native renderers use (the same layout as build_bw.py).

Upstream dev BW profiles carry one channel and, for negatives and print films, a
family of development times (one density-curve / base+fog column each). This
keeps the upstream default member (the middle development time, as
select_development_time does with no choice made), then:
  - log_sensitivity: the single channel in all three; NaN (no sensitivity) becomes
    6 decades under the peak;
  - density_curves / density_curves_layers: the chosen column in all three;
    density_curves_model: the chosen row, "cdfs" (the Gaussian-cdf model);
  - channel_density: spectrally flat silver, 1/3 per channel;
  - base_density: the chosen column; midscale_neutral_density: base + the density
    at log exposure 0;
  - hanatos2025 adaptation data: from --adapt (a structural stock) for camera films,
    none for print films.
Print filter entries are copied from --filters-from for every paper.

Usage:
  python convert_upstream_bw.py SRC.json [--target-print kodak_2302]
        [--adapt kodak_tri_x_400] [--filters-from kodak_tri_x_400]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_positive import FILTER_FILES, OFX, PROFILE_DIRS  # noqa: E402


def convert(a: argparse.Namespace) -> None:
    src = json.loads(Path(a.src).read_text())
    info, d = src["info"], src["data"]
    stock = info["stock"]
    times = np.atleast_1d(np.asarray(d.get("development_time") or [1.0], float))
    k = (times.size - 1) // 2

    three = lambda v: np.repeat(np.asarray(v, float)[..., None], 3, axis=-1)
    le = np.asarray(d["log_exposure"], float)
    curve = np.asarray(d["density_curves"], float).reshape(le.size, -1)[:, k]
    layers = np.asarray(d["density_curves_layers"], float).reshape(le.size, 3, -1)[:, :, k]
    wl = np.asarray(d["wavelengths"], float)
    base = np.asarray(d["base_density"], float).reshape(wl.size, -1)[:, k]
    ls = np.asarray(d["log_sensitivity"], float).reshape(wl.size)
    ls = np.where(np.isnan(ls), np.nanmax(ls) - 6.0, ls)
    model = d["density_curves_model"]
    row = lambda key: list(map(float, model[key][k]))

    out_info = dict(info)
    out_info.update(target_print=a.target_print)
    out = {
        "info": out_info,
        "data": {
            "wavelengths": wl.tolist(),
            "log_sensitivity": three(ls).tolist(),
            "channel_density": np.full((wl.size, 3), 1.0 / 3.0).tolist(),
            "base_density": base.tolist(),
            "midscale_neutral_density": (base + float(np.interp(0.0, le, curve))).tolist(),
            "log_exposure": le.tolist(),
            "density_curves": three(curve).tolist(),
            "density_curves_layers": np.repeat(layers[:, :, None], 3, axis=2).tolist(),
            "density_curves_model": {"model_type": "cdfs", "centers": [row("centers")] * 3,
                                     "amplitudes": [row("amplitudes")] * 3, "sigmas": [row("sigmas")] * 3},
        },
        "metadata": dict(src.get("metadata", {})),
    }
    if a.adapt:
        adapt = json.loads((OFX / "profiles" / f"{a.adapt}.json").read_text())["data"]
        for key in ("hanatos2025_adaptation_window_params", "hanatos2025_adaptation_surface_params"):
            out["data"][key] = adapt[key]
    else:
        out["data"]["hanatos2025_adaptation_window_params"] = []
        out["data"]["hanatos2025_adaptation_surface_params"] = []
    picked = f"development time {times[k]:g} min" if times.size > 1 else "single development"
    out["metadata"]["derivation"] = (
        f"Converted by PhotoEmul from the spektrafilm dev-branch profile: {picked} of "
        f"{times.tolist()} (the upstream default); one channel repeated into three identical channels "
        f"with spectrally flat silver (1/3 each); no-sensitivity wavelengths set 6 decades under the peak; "
        + (f"hanatos2025 adaptation data from {a.adapt}." if a.adapt else "no hanatos2025 adaptation data."))
    print(f"{stock}: {picked}, D at le 0 {np.interp(0.0, le, curve):.3f}, max {curve.max():.2f}, "
          f"base {base.mean():.3f}, sensitivity peak {wl[np.argmax(ls)]:.0f} nm")
    for directory in PROFILE_DIRS:
        (directory / f"{stock}.json").write_text(json.dumps(out, indent=4))
    if a.filters_from:
        for f in FILTER_FILES:
            filters = json.loads(f.read_text())
            for paper in filters.values():
                for table in paper.values():
                    if a.filters_from in table:
                        table[stock] = table[a.filters_from]
            f.write_text(json.dumps(filters, indent=4))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--target-print")
    ap.add_argument("--adapt")
    ap.add_argument("--filters-from")
    convert(ap.parse_args())
