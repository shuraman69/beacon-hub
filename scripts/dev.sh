#!/usr/bin/env bash
# Быстрый debug-запуск прямо из build/, логи пишутся в терминал. Ctrl+C останавливает.
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -x BeaconHub 2>/dev/null && sleep 0.5 || true
CONFIG=debug ./scripts/build.sh
exec "build/Beacon Hub.app/Contents/MacOS/BeaconHub"
