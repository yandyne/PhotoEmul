#!/bin/zsh
# Builds PhotoEmul.app (GPL-3.0-or-later).
#   app/build.sh            -> app/build/PhotoEmul.app
set -euo pipefail
ROOT="${0:A:h:h}"
APP_DIR="$ROOT/app"
# Universal (Apple silicon + Intel) engine build; see README for the cmake line.
ENGINE="$ROOT/build/ofx/SpektraFilm/build-universal"
MIN_MACOS="${MIN_MACOS:-14.0}"
ARCHS=(${=ARCHS:-arm64 x86_64})
OUT="$APP_DIR/build"
BUNDLE="$OUT/PhotoEmul.app"

make -C "$ENGINE" SpektraFilmAppCore -j8 >/dev/null

mkdir -p "$OUT/obj" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
slices=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macosx$MIN_MACOS" \
    -module-name PhotoEmul \
    -I "$APP_DIR/CSpektra" \
    "$APP_DIR"/Sources/*.swift \
    "$ENGINE/libSpektraFilmAppCore.a" -lc++ \
    -framework Metal -framework MetalKit -framework MetalPerformanceShaders \
    -framework Foundation -framework CoreGraphics -framework AppKit -framework SwiftUI \
    -framework ImageIO -framework CoreImage -framework UniformTypeIdentifiers -framework WebKit \
    -o "$OUT/obj/PhotoEmul-$arch"
  slices+=("$OUT/obj/PhotoEmul-$arch")
done
lipo -create "${slices[@]}" -output "$BUNDLE/Contents/MacOS/PhotoEmul"

cp "$APP_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$BUNDLE/Contents/Info.plist"
# Every successful build gets the next build number, shown in About as "0.1.N (date)".
BUILD_FILE="$APP_DIR/BUILD_NUMBER"
BUILD=$(cat "$BUILD_FILE" 2>/dev/null || echo 0)
# Only the development repo (it has tools/publish.sh, which is not published) counts builds up;
# clones of the public repo build the published number and leave the file untouched.
if [[ -f "$ROOT/tools/publish.sh" ]]; then BUILD=$(( BUILD + 1 )); echo $BUILD > "$BUILD_FILE"; fi
BASE_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_DIR/Info.plist")
plutil -replace CFBundleShortVersionString -string "$BASE_VERSION.$BUILD" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y.%m.%d.%H%M)" "$BUNDLE/Contents/Info.plist"
plutil -replace NSHumanReadableCopyright -string "spektrafilm · GPL-3.0-or-later · build $BUILD, $(date '+%Y-%m-%d %H:%M')" "$BUNDLE/Contents/Info.plist"
echo "PhotoEmul $BASE_VERSION.$BUILD"
cp "$ENGINE/SpektraFilm.metallib" "$BUNDLE/Contents/Resources/"
cp "$APP_DIR/AppIcon.icns" "$BUNDLE/Contents/Resources/"
cp "$APP_DIR/Credits.html" "$BUNDLE/Contents/Resources/"
cp "$APP_DIR/LensProfiles.json" "$BUNDLE/Contents/Resources/"
rm -rf "$BUNDLE/Contents/Resources/AI Add-ins Examples"
cp -Rp "$APP_DIR/AI Add-ins Examples" "$BUNDLE/Contents/Resources/"
# App-side effect kernels: precompiled so launch skips the runtime shader compile.
cp "$APP_DIR/Shaders/Effects.metal" "$BUNDLE/Contents/Resources/"
if xcrun -f metal >/dev/null 2>&1; then
  xcrun metal -O3 -mmacosx-version-min="$MIN_MACOS" -c "$APP_DIR/Shaders/Effects.metal" -o "$OUT/obj/Effects.air"
  xcrun metallib "$OUT/obj/Effects.air" -o "$BUNDLE/Contents/Resources/Effects.metallib"
else
  rm -f "$BUNDLE/Contents/Resources/Effects.metallib"
fi
for f in SpektraHanatos2025Spectra.f32 SpektraOutputGamutCompression.f32; do
  cp "$ENGINE/generated_parity/$f" "$BUNDLE/Contents/Resources/"
done
for f in LICENSE.txt LICENSE; do [[ -f "$ROOT/build/ofx/SpektraFilm/$f" ]] && { cp "$ROOT/build/ofx/SpektraFilm/$f" "$BUNDLE/Contents/Resources/LICENSE.txt"; break; }; done
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
echo "$BUNDLE"
