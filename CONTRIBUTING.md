# Contributing

PhotoEmul is a personal project: pull requests are not accepted and issues are turned off.
You are welcome to fork it and change it yourself under the [GPL-3.0](LICENSE). This page is for people who do.

## Build and check

Follow **Build yourself** in the [README](README.md) (Xcode with the Metal Toolchain, CMake, Python 3, `git clone --recursive`). Then:

```sh
app/build.sh                                                   # universal app in app/build/PhotoEmul.app
app/build/PhotoEmul.app/Contents/MacOS/PhotoEmul --self-test   # exit code 0 when all checks pass
```

`ARCHS=arm64 app/build.sh` builds for Apple silicon only, which is faster while you work.
The build number shown in About is the one in `app/BUILD_NUMBER`; builds of a clone do not change it.

## The engine

The engine is the `build/ofx/SpektraFilm` submodule: [yandyne/spektrafilm-ofx](https://github.com/yandyne/spektrafilm-ofx), branch `photoemul`,
which is [chaert-s/spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx) with PhotoEmul's changes on top.
To change it, fork that repository too and point the submodule at your fork.

## If you publish a fork

- Keep it GPL-3.0-or-later, publish your source with your builds, and keep [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `app/Credits.html`.
- Film or paper profiles derived from spektrafilm data are CC BY-SA 4.0: give each changed profile a “derivation” note saying what was changed.
- Use your own app name and bundle identifier (`com.yandyne.PhotoEmul` in `app/Info.plist`), so your build does not share settings with PhotoEmul.
