#!/usr/bin/env bash
# Собирает, ставит в /Applications и перезапускает Beacon Hub.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Beacon Hub"
DEST="/Applications/${APP_NAME}.app"

./scripts/build.sh

echo "▸ останавливаю запущенную копию"
pkill -x BeaconHub 2>/dev/null && sleep 0.5 || true

echo "▸ копирую в /Applications"
rm -rf "$DEST"
ditto "build/${APP_NAME}.app" "$DEST"

echo "▸ запускаю"
open "$DEST"
echo "✓ Готово: ищи маяк в статус-баре"
