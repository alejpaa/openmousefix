#!/usr/bin/env bash
# OpenMouseFix installer.
#   Install / update:  curl -fsSL https://raw.githubusercontent.com/alejpaa/openmousefix/main/install.sh | bash
#   Uninstall:         curl -fsSL https://raw.githubusercontent.com/alejpaa/openmousefix/main/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO="alejpaa/openmousefix"
APP_NAME="OpenMouseFix"
BUNDLE_ID="io.github.alejpaa.openmousefix"
DEST="/Applications/$APP_NAME.app"
# Optional: build a specific branch/tag from source instead of the latest release (for testing).
REF="${OPENMOUSEFIX_REF:-}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "OpenMouseFix solo funciona en macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "Se necesita macOS 13 o superior."

# Use sudo only if /Applications is not writable by this user.
SUDO=""
[[ -w /Applications ]] || SUDO="sudo"

quit_app() { pkill -x "$APP_NAME" 2>/dev/null || true; sleep 0.5; }

if [[ "${1:-}" == "--uninstall" ]]; then
  info "Desinstalando ${APP_NAME}…"
  quit_app
  $SUDO rm -rf "$DEST"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  info "Listo."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Prebuilt app from the latest GitHub release (skipped when a source ref is requested).
if [[ -z "$REF" ]] && curl -fsSL -o "$TMP/app.zip" "https://github.com/$REPO/releases/latest/download/$APP_NAME.zip" 2>/dev/null; then
  info "Descargada la última versión publicada."
  ditto -x -k "$TMP/app.zip" "$TMP"
else
  # 2) No release yet: build from source (needs Command Line Tools).
  info "Compilando desde el código fuente${REF:+ ($REF)}…"
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "Faltan las Command Line Tools. Termina su instalación y vuelve a ejecutar este comando."
  fi
  git clone --depth 1 ${REF:+--branch "$REF"} "https://github.com/$REPO.git" "$TMP/src" >/dev/null 2>&1 \
    || fail "No se pudo descargar el código fuente."
  (cd "$TMP/src" && ./build.sh) || fail "La compilación falló."
  mv "$TMP/src/build/$APP_NAME.app" "$TMP/"
fi

[[ -d "$TMP/$APP_NAME.app" ]] || fail "No se encontró $APP_NAME.app."

info "Instalando en ${DEST}…"
quit_app
$SUDO rm -rf "$DEST"
$SUDO ditto "$TMP/$APP_NAME.app" "$DEST"
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Each build has a new ad-hoc signature, so an old Accessibility grant would silently stop
# working. Reset it so macOS asks again cleanly.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

open "$DEST"
info "¡Instalado! Concede el permiso en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad."
