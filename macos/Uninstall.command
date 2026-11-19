#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OBIT Auto-Auth.app"
BUNDLE_ID="ru.obit.autoauth"
PLIST_PATH="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"

echo "[1/3] Остановка OBIT Auto-Auth..."
pkill -x ObitAutoAuth >/dev/null 2>&1 || true

echo "[2/3] Удаление автозапуска..."
rm -f "$PLIST_PATH"

echo "[3/3] Удаление приложения и данных..."
rm -rf "/Applications/${APP_NAME}" "${HOME}/Applications/${APP_NAME}"
rm -rf "${HOME}/Library/Logs/ObitAutoAuth"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

echo ""
echo "OBIT Auto-Auth полностью удалён."
sleep 2
