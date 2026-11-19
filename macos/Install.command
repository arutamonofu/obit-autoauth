#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OBIT Auto-Auth.app"
BUNDLE_ID="ru.obit.autoauth"
PLIST_PATH="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"

SOURCE_APP="${SCRIPT_DIR}/${APP_NAME}"
if [[ ! -d "$SOURCE_APP" ]]; then
    SOURCE_APP="${SCRIPT_DIR}/../dist/${APP_NAME}"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    if [[ -x "${SCRIPT_DIR}/build.sh" ]] && command -v swiftc >/dev/null 2>&1; then
        echo "[1/4] Сборка ${APP_NAME}..."
        "${SCRIPT_DIR}/build.sh"
        SOURCE_APP="${SCRIPT_DIR}/../dist/${APP_NAME}"
    else
        echo "[ERROR] Рядом не найден ${APP_NAME} и недоступен swiftc для сборки." >&2
        read -r -p "Нажмите Enter для закрытия..."
        exit 1
    fi
fi

if [[ -w "/Applications" ]]; then
    TARGET_DIR="/Applications"
else
    TARGET_DIR="${HOME}/Applications"
    mkdir -p "$TARGET_DIR"
fi
TARGET_APP="${TARGET_DIR}/${APP_NAME}"
EXEC_PATH="${TARGET_APP}/Contents/MacOS/ObitAutoAuth"

echo "[2/4] Остановка старой версии (если запущена)..."
pkill -x ObitAutoAuth >/dev/null 2>&1 || true
sleep 1

echo "[3/4] Установка в ${TARGET_APP}..."
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true

echo "[4/4] Настройка автозапуска и запуск..."
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

open "$TARGET_APP"

echo ""
echo "Готово! Круглая иконка OBIT Auto-Auth появилась в строке меню (вверху справа)."
echo "Программа будет автоматически запускаться при входе в macOS."
sleep 3
