#!/usr/bin/env bash
# Универсальная сборка (Apple Silicon + Intel) и zip для отправки другим людям.
# Если есть сертификат Developer ID и профиль notarytool (NOTARY_PROFILE), zip будет нотаризован.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Beacon Hub"
VERSION="$(cat VERSION)"
ZIP="dist/BeaconHub-${VERSION}.zip"

UNIVERSAL=1 ./scripts/build.sh

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "build/${APP_NAME}.app" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ нотаризация (профиль ${NOTARY_PROFILE})"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "build/${APP_NAME}.app"
  rm -f "$ZIP"
  ditto -c -k --keepParent "build/${APP_NAME}.app" "$ZIP"
fi

echo "✓ $ZIP"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  cat <<'EOF'

Сборка не нотаризована. Получателю после распаковки нужно один раз выполнить:
  xattr -dr com.apple.quarantine "/Applications/Beacon Hub.app"
(или ПКМ по приложению → «Открыть»)
EOF
fi
