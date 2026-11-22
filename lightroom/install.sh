#!/bin/bash
# Install PhotoEmul.lrplugin into Lightroom Classic's Modules folder and
# point it at PhotoEmul.app (app/build.sh).
#
#   lightroom/install.sh            # install / update
#   lightroom/install.sh --uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(dirname "$HERE")"
MODULES="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
TARGET="$MODULES/PhotoEmul.lrplugin"
# Folder names before 0.1.53 / 0.1.122; same toolkit id, so only one may stay.
OLD_TARGETS=("$MODULES/spektrafilm.lrplugin" "$MODULES/Emulsa.lrplugin")
APP="$PROJECT/app/build/PhotoEmul.app"

if [[ "${1:-}" == "--uninstall" ]]; then
	rm -rf "$TARGET" "${OLD_TARGETS[@]}"
	echo "removed $TARGET"
	exit 0
fi

[[ -x "$APP/Contents/MacOS/PhotoEmul" ]] || { echo "PhotoEmul.app not built ($APP): run app/build.sh first" >&2; exit 1; }
echo "editor: $APP"

lua_string() { # escape for a double-quoted Lua string
	printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

mkdir -p "$MODULES"
rm -rf "$TARGET" "${OLD_TARGETS[@]}"
cp -R "$HERE/PhotoEmul.lrplugin" "$TARGET"
cat > "$TARGET/Config.lua" <<EOF
-- Written by lightroom/install.sh. Can be overridden in
-- File > Plug-in Manager > PhotoEmul.
return {
	appPath = $(lua_string "$APP"),
}
EOF
echo "installed $TARGET"
echo "Restart Lightroom Classic (or File > Plug-in Manager > Reload Plug-in)."
if pgrep -x "Adobe Lightroom Classic" >/dev/null; then
  # A running Lightroom keeps the plug-in at the path it loaded; a moved folder needs a restart.
  echo "Lightroom Classic is running: quit and reopen it before using the plug-in."
fi
