#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OpenMouseFix.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OpenMouseFix"
else
  swift build -c release --arch arm64
  BIN="$(swift build -c release --arch arm64 --show-bin-path)/OpenMouseFix"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenMouseFix"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
echo "App creada: $(pwd)/$APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x OpenMouseFix || true
  sleep 0.5
  rm -rf /Applications/OpenMouseFix.app
  cp -R "$APP" /Applications/OpenMouseFix.app
  echo "Instalada en /Applications/OpenMouseFix.app"
fi
