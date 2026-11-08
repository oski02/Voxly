#!/bin/bash
# Voxly installer / Instalador de Voxly
# Descarga la última release, verifica el SHA-256, la instala y la abre.
# Downloads the latest release, verifies its SHA-256, installs and opens it.
#
# Uso / Usage:
#   curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors https://raw.githubusercontent.com/oski02/Voxly/main/install.sh | bash
set -euo pipefail

REPO="oski02/Voxly"
API="${VOXLY_API:-https://api.github.com}"
APP="Voxly.app"
DEST="${INSTALL_DIR:-/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Voxly solo funciona en macOS / Voxly only runs on macOS."
[ "$(uname -m)" = "arm64" ]  || die "Esta versión es solo para Apple Silicon (arm64) / This build is Apple Silicon only."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Buscando la última versión / Looking up the latest release..."
JSON="$(curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors "$API/repos/$REPO/releases/latest")" || die "No se pudo consultar GitHub / Could not reach GitHub."
FLAT="$(printf '%s' "$JSON" | tr -d ' \n')"
# Id del asset por nombre (regex) / Asset id by name (regex)
asset_id() { printf '%s' "$FLAT" | grep -oE "releases/assets/[0-9]+\",\"id\":[0-9]+,\"node_id\":\"[^\"]*\",\"name\":\"$1\"" | head -1 | sed -E 's#releases/assets/([0-9]+)".*#\1#'; }
ZIP_ID="$(asset_id '[^"]*\.zip')"
SUM_ID="$(asset_id 'SHA256\.txt')"
[ -n "$ZIP_ID" ] && [ -n "$SUM_ID" ] || die "La release no contiene el zip o el SHA256.txt / Release is missing the zip or SHA256.txt."

# Descarga por la API (más fiable que github.com/.../download) / Download via the API
fetch() { curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors -H "Accept: application/octet-stream" -o "$2" "$API/repos/$REPO/releases/assets/$1"; }

say "Descargando / Downloading Voxly..."
fetch "$ZIP_ID" "$TMP/app.zip" || die "No se pudo descargar el zip / Could not download the zip."
fetch "$SUM_ID" "$TMP/SHA256.txt" || die "No se pudo descargar SHA256.txt / Could not download SHA256.txt."

say "Verificando integridad / Verifying checksum..."
EXPECTED="$(awk '{print $1}' "$TMP/SHA256.txt" | head -1)"
ACTUAL="$(shasum -a 256 "$TMP/app.zip" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "El SHA-256 no coincide, instalación cancelada / Checksum mismatch, aborting."

say "Extrayendo / Extracting..."
ditto -x -k "$TMP/app.zip" "$TMP/out"
[ -d "$TMP/out/$APP" ] || die "No se encontró $APP en el zip / $APP not found in the zip."

if pgrep -x Voxly >/dev/null 2>&1; then
  say "Cerrando Voxly en ejecución / Quitting running Voxly..."
  osascript -e 'tell application "Voxly" to quit' >/dev/null 2>&1 || pkill -x Voxly || true
  sleep 1
fi

say "Instalando en / Installing to $DEST..."
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
ditto "$TMP/out/$APP" "$DEST/$APP"
# Evita el aviso de Gatekeeper para esta app sin notarizar / Avoids the Gatekeeper warning
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

say "Listo / Done: $DEST/$APP"
if [ -z "${NO_OPEN:-}" ]; then
  open "$DEST/$APP"
  echo "Concede Micrófono, Reconocimiento de voz y Accesibilidad cuando se pida."
  echo "Grant Microphone, Speech Recognition and Accessibility when prompted."
fi
