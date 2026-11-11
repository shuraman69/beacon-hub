#!/usr/bin/env bash
# Сборка build/Beacon Hub.app
#   CONFIG=release|debug   (по умолчанию release)
#   UNIVERSAL=1            собрать под arm64 + x86_64 (для раздачи)
#   SIGN_IDENTITY="..."    сертификат подписи; по умолчанию первый «Apple Development», иначе ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Beacon Hub"
EXEC_NAME="BeaconHub"
CONFIG="${CONFIG:-release}"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="build/${APP_NAME}.app"

arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

echo "▸ swift build (${CONFIG}$([[ "${UNIVERSAL:-0}" == "1" ]] && echo ", universal"))"
swift build -c "$CONFIG" ${arch_flags[@]+"${arch_flags[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ генерирую иконку"
  swiftc -O scripts/make-icon.swift -o .build/make-icon && .build/make-icon Resources/AppIcon.icns
fi

echo "▸ собираю бандл"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

# Подпись. Ищем по SHA-1 отпечатку: codesign не всегда находит сертификат по имени с кириллицей.
pick_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"($1[^\"]*)\".*/\1|\2/p" | head -1
}
identity="${SIGN_IDENTITY:-}"
label="$identity"
if [[ -z "$identity" ]]; then
  found="$(pick_identity 'Developer ID Application:')"
  [[ -z "$found" ]] && found="$(pick_identity 'Apple Development:')"
  if [[ -n "$found" ]]; then identity="${found%%|*}"; label="${found#*|}"; fi
fi
if [[ -z "$identity" ]]; then identity="-"; label="ad-hoc"; fi

echo "▸ подпись: $label"
if ! codesign --force --deep --timestamp=none --sign "$identity" "$APP"; then
  echo "  ⚠ не удалось подписать сертификатом, подписываю ad-hoc"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ $APP (v${VERSION}, build ${BUILD_NUMBER})"
