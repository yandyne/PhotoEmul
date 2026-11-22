"""Fit the neutral print filters (Kodak CC, cyan held at 0) of film stocks with the
upstream spektrafilm simulation: an 18% grey frame must print with the same colour
balance as the reference stock (Portra 400) gives with its database filters (the
database filters are not exactly neutral by this test, so the reference balance is
matched instead of R = G = B).

Usage:
  python fit_bw_filters.py STOCK [STOCK ...] [--check kodak_portra_400]
  python fit_bw_filters.py [STOCK ...] --paper NEW --like kodak_2383
--check refits a stock that already has database entries and prints both, to
validate the fit against the published values.
--paper fits on that paper only (every stock in its table when none is named),
matching the balance Portra 400 gets on the --like paper with its database filters.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_positive import FILTER_FILES, PY  # noqa: E402

sys.path.insert(0, str(PY.parents[1]))
from spektrafilm.model.couplers import compute_dir_couplers_matrix  # noqa: E402
from spektrafilm.runtime.params_builder import init_params  # noqa: E402
from spektrafilm.runtime.process import simulate  # noqa: E402

GREY = np.full((4, 4, 3), 0.184)
DIR_INVERSION_MIN_SLOPE = 0.25  # as dirInversionScale in the native renderers


def limit_dir_couplers(params) -> None:
    """Scale the DIR coupler amount down, as the native renderers do, when steep
    curves would fold the coupler inversion (log exposure 0 not monotonic)."""
    data = params.film.data
    dc = np.asarray(data.density_curves, float)
    le = np.asarray(data.log_exposure, float)
    silver = np.nanmax(dc, axis=0) - dc if params.film.is_positive else dc
    m = compute_dir_couplers_matrix(params.film_render.dir_couplers) * params.film_render.dir_couplers.amount
    worst = float(np.nanmax(np.diff(silver, axis=0) / np.diff(le)[:, None] @ m))
    if worst > 1.0 - DIR_INVERSION_MIN_SLOPE:
        params.film_render.dir_couplers.amount *= (1.0 - DIR_INVERSION_MIN_SLOPE) / worst


def print_rgb(film: str, paper: str, illuminant: str, m: float, y: float) -> np.ndarray:
    params = init_params(film_profile=film, print_profile=paper)
    limit_dir_couplers(params)
    params.settings.neutral_print_filters_from_database = False
    params.debug.lut_mode = True
    params.io.input_color_space = "sRGB"
    params.io.output_cctf_encoding = False
    params.enlarger.illuminant = illuminant
    params.enlarger.c_filter_neutral = 0.0
    params.enlarger.m_filter_neutral = m
    params.enlarger.y_filter_neutral = y
    return np.asarray(simulate(GREY, params), float).reshape(-1, 3).mean(axis=0)


def balance(rgb: np.ndarray) -> np.ndarray:
    log = np.log10(np.maximum(rgb, 1e-6))
    return np.array([log[0] - log[1], log[2] - log[1]])


def fit(film: str, paper: str, illuminant: str, start: tuple[float, float],
        target: np.ndarray) -> tuple[float, float, np.ndarray]:
    def residual(p):
        return balance(print_rgb(film, paper, illuminant, *p)) - target

    r = least_squares(residual, start, bounds=([0, 0], [200, 200]), diff_step=1e-3, xtol=1e-4)
    return float(r.x[0]), float(r.x[1]), print_rgb(film, paper, illuminant, *r.x)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("stocks", nargs="*")
    ap.add_argument("--check")
    ap.add_argument("--paper")
    ap.add_argument("--like")
    a = ap.parse_args()
    database = json.loads(FILTER_FILES[0].read_text())
    papers = {a.paper: database[a.paper]} if a.paper else database
    stocks = a.stocks or (sorted({s for t in papers[a.paper].values() for s in t}) if a.paper else [])
    targets: dict = {}

    def target(paper: str, illuminant: str) -> np.ndarray:
        ref_paper = a.like if a.paper else paper
        if (ref_paper, illuminant) not in targets:
            ref = database[ref_paper][illuminant]["kodak_portra_400"]
            targets[ref_paper, illuminant] = balance(
                print_rgb("kodak_portra_400", ref_paper, illuminant, ref[1], ref[2]))
        return targets[ref_paper, illuminant]

    found: dict = {}
    for stock in ([a.check] if a.check else []) + stocks:
        for paper, tables in papers.items():
            for illuminant, table in tables.items():
                start = table.get(stock, table["kodak_portra_400"])
                m, y, rgb = fit(stock, paper, illuminant, tuple(start[1:]), target(paper, illuminant))
                print(f"{stock} / {paper} / {illuminant}: M {m:.1f} Y {y:.1f}  rgb {np.round(rgb, 4)}"
                      + (f"  database {np.round(table.get(stock), 1)}" if stock == a.check else ""),
                      flush=True)
                if stock != a.check:
                    found.setdefault(paper, {}).setdefault(illuminant, {})[stock] = [0.0, m, y]
    for f in FILTER_FILES:
        filters = json.loads(f.read_text())
        for paper, tables in found.items():
            for illuminant, table in tables.items():
                filters[paper][illuminant].update(table)
        f.write_text(json.dumps(filters, indent=4))


if __name__ == "__main__":
    main()
