# Third-party notices

PhotoEmul is free software under the GNU General Public License v3.0 or later ([LICENSE](LICENSE)).
It is built on the spektrafilm spectral film engine. The software, data and methods it uses are listed below with their licenses.
The same list is shown in the app (About › Credits, from `app/Credits.html`).

## Engines

**spektrafilm OFX** — Aedan Diez ([github.com/chaert-s/spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx), spektrafilm.114c.de), GPL-3.0.
The GPU rendering core (SpektraFilmAppCore, SpektraFilm.metallib) is built from the spektrafilm OFX source, included here as the
`build/ofx/SpektraFilm` submodule ([yandyne/spektrafilm-ofx](https://github.com/yandyne/spektrafilm-ofx), branch `photoemul`).
PhotoEmul is a user-built derivative of that GPL source, not an official OFX binary distribution; the official-binary notice and the
exported-LUT license of the OFX project do not apply to it.

**spektrafilm** (reference implementation) — Andrea Volpato, [github.com/andreavolpato/spektrafilm](https://github.com/andreavolpato/spektrafilm), GPL-3.0.
The density-emulation model, the negative → print → scan pipeline and the profile-generation foundation come from this work.
*Spectral film modeling powered by spektrafilm.* Please cite the repository / Zenodo DOI (CITATION.cff) in academic work.

## Spectral colour science

- **Hanatos 2025 spectral upsampling** — Johannes Hanika, vkdt ([github.com/hanatos/vkdt](https://github.com/hanatos/vkdt)), GPL-3.0.
  The bundled `SpektraHanatos2025Spectra.f32` is the spectral upsampling table in the Hanatos 2025 model direction.
- **Mallett & Yuksel 2019**, “Spectral Primary Decomposition for Rendering with sRGB Reflectance”, EGSR 2019.
  The alternate spectral reconstruction path follows this method.
- **CIE standard observer and illuminants** — CIE 1931 colour-matching functions, illuminant A and the D series are public CIE definitions.
  Scene light spectra are analytic models written for PhotoEmul (Planck's law, Gaussian emission bands); no measured lamp tables are included.
- **Build-time table generation** uses **colour-science**, **NumPy** and **SciPy** (all BSD-3-Clause).
  None of them ship inside the app; only the tables they produce do.

## Film, paper and filter data

**spektrafilm profiles** — Andrea Volpato and contributors, **CC BY-SA 4.0** (SPEKTRAFILM_LICENSE.txt in the spektrafilm repository).
The JSON film, paper, enlarger-filter and LUT data in the engine's data folder are these profiles. Profiles PhotoEmul derived from them
(Ilford, T-Max, Eterna, instant films, developer variants and others) carry a “derivation” note describing the change, as CC BY-SA requires,
and are shared under the same CC BY-SA 4.0 license. Characteristic curves, spectral sensitivities and dye densities were digitised from the
manufacturers' public technical datasheets (Kodak, Fujifilm, Ilford / Harman, Polaroid, CineStill).

**Reciprocity failure** fits follow the manufacturers' public datasheets; the fits are PhotoEmul's own.

## Lens profiles

**lensfun database** ([lensfun.github.io](https://lensfun.github.io)) — distortion, lateral chromatic aberration and vignetting profiles,
converted by PhotoEmul's own parser into `LensProfiles.json`. The lensfun database is licensed under **CC BY-SA 3.0**;
the converted `LensProfiles.json` is shared under the same license.

## Dust & scratches

**FilmDamageSimulator** ([github.com/daniela997/FilmDamageSimulator](https://github.com/daniela997/FilmDamageSimulator)) — the dust and scratch
statistics were measured from its annotations. D. Ivanova, J. Williamson, P. Henderson, “Simulating Analogue Film Damage to Analyse and
Improve Artefact Restoration on High-resolution Scans”, Eurographics 2023.

```
MIT License — Copyright (c) 2022 Daniela Ivanova

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## OpenFX SDK

The engine source vendors the **OpenFX** SDK headers (Academy Software Foundation,
[github.com/AcademySoftwareFoundation/openfx](https://github.com/AcademySoftwareFoundation/openfx), release OFX_Release_1.5.1).
PhotoEmul does not load an OFX host, but the headers are part of the engine tree.

```
BSD 3-Clause License — Copyright (c) 2025, OpenFX and contributors to the OpenFX project

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The vendored header `ofxKeySyms.h` also carries X Consortium (1987, 1994) and Digital Equipment Corporation (1987) permission notices;
see THIRD_PARTY_NOTICES.txt in the engine source.

## Lightroom Classic plug-in

The optional `PhotoEmul.lrplugin` is written against the Adobe Lightroom Classic SDK (Lua) and is GPL-3.0 like the app.
It hands photos to PhotoEmul.app for editing and bundles no third-party code.

## Apple frameworks

SwiftUI, AppKit, Metal, MetalKit, Metal Performance Shaders, Core Image, ImageIO, WebKit and Uniform Type Identifiers are macOS system
frameworks under Apple's SDK license; nothing from them is redistributed.

## Trademarks

spektrafilm is the name of Andrea Volpato's project. Kodak, Fujifilm, Ilford, Harman, Polaroid, CineStill, Lightroom and other product names
belong to their owners and are used only to identify the materials being simulated. PhotoEmul is not endorsed by any of them.
