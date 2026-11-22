"""Bake spektrafilm film/print simulations into Lightroom Look profiles.

Each (film, print) pair is baked as a 32^3 combined LUT with the
spektrafilm LUT creator (deterministic ``lut_mode``: no grain/halation),
then packed into an Adobe RGBTable XMP profile.

    python -m sf4lr.bake --out build/profiles
    python -m sf4lr.bake --films kodak_portra_400 --prints kodak_portra_endura
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from .rgbtable import MAX_DIVISIONS_3D, RGBTable
from .xmp_profile import LookProfile, write_xmp

NEGATIVE_PRINTS = {
    "kodak_portra_endura": "Portra Endura",
    "fujifilm_crystal_archive_typeii": "Crystal Archive",
    "kodak_2383": "Vision 2383",
}

ATTRIBUTION = (
    "film modeling powered by spektrafilm (Andrea Volpato). "
    "Profile data CC BY-SA 4.0; code GPLv3."
)


def profile_display_name(profile: str) -> str:
    from spektrafilm.profiles.io import load_profile  # deferred heavy import

    return load_profile(profile).info.name


def is_positive(profile: str) -> bool:
    from spektrafilm.profiles.io import load_profile

    return bool(load_profile(profile).is_positive)


def bake_table(film: str, print_stock: str, *, resolution: int = MAX_DIVISIONS_3D,
               stops_above_midgray: float | str | None = None) -> np.ndarray:
    """Return samples indexed ``[r, g, b] -> rgb`` (sRGB encoded, [0, 1])."""
    from spektrafilm_lut_creator.builders import BundleBuilder
    from spektrafilm_lut_creator.bundles import BundleSpec

    spec = BundleSpec(
        film_profile=film,
        print_profiles=(print_stock,),
        input_color_space="sRGB",
        output_color_space="sRGB",
        resolution=resolution,
        stops_above_midgray=stops_above_midgray,
    )
    bundle = BundleBuilder(spec).build()
    table = bundle.luts[0][1].table  # .cube order: indexed [b, g, r]
    return np.ascontiguousarray(table.transpose(2, 1, 0, 3))


def bake_profile(film: str, print_stock: str, out_dir: Path, **kwargs) -> Path:
    film_name = profile_display_name(film)
    positive = is_positive(film)
    if positive:
        group = "spektrafilm · Slide"
        name = film_name
        desc = f"{film_name} (reversal). {ATTRIBUTION}"
    else:
        print_label = NEGATIVE_PRINTS.get(print_stock, profile_display_name(print_stock))
        group = f"spektrafilm · {print_label}"
        name = f"{film_name} · {print_label}"
        desc = f"{film_name} printed on {profile_display_name(print_stock)}. {ATTRIBUTION}"
    samples = bake_table(film, print_stock, **kwargs)
    look = LookProfile(
        name=name,
        group=group,
        table=RGBTable(samples=samples, primaries="sRGB", gamma="sRGB", gamut="clip"),
        description=desc,
        copyright="spektrafilm (GPLv3) / profile data CC BY-SA 4.0",
        contact="https://github.com/andreavolpato/spektrafilm",
    )
    safe = name.replace("·", "-").replace("/", "-")
    sub = group.replace("·", "-").replace("/", "-")
    return write_xmp(look, out_dir / sub / f"{safe}.xmp")


def all_films() -> list[str]:
    from spektrafilm_lut_creator.cli import _list_profiles_by_stage

    return _list_profiles_by_stage("filming")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("build/profiles/spektrafilm"))
    ap.add_argument("--films", nargs="*", help="film profiles (default: all)")
    ap.add_argument("--prints", nargs="*", default=list(NEGATIVE_PRINTS),
                    help="print profiles used for negative films")
    ap.add_argument("--stops-above-midgray", default=None,
                    help="input exposure: omit for native (midgray preserved), 'auto' or a float")
    ap.add_argument("--resolution", type=int, default=MAX_DIVISIONS_3D)
    args = ap.parse_args(argv)

    stops = args.stops_above_midgray
    if stops not in (None, "auto"):
        stops = float(stops)
    films = args.films or all_films()
    written = []
    for film in films:
        prints = args.prints[:1] if is_positive(film) else args.prints
        for print_stock in prints:
            path = bake_profile(film, print_stock, args.out,
                                resolution=args.resolution, stops_above_midgray=stops)
            written.append(str(path))
            print(f"wrote {path}", file=sys.stderr)
    (args.out / "manifest.json").write_text(json.dumps(written, indent=1, ensure_ascii=False))
    print(f"{len(written)} profiles in {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
