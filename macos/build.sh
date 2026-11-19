#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_NAME="OBIT Auto-Auth.app"
APP_DIR="${DIST_DIR}/${APP_NAME}"
OUT_ZIP="${DIST_DIR}/OBIT-AutoAuth-macOS.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Ошибка: сборка macOS-приложения должна выполняться на macOS (требуется swiftc и Apple SDK)." >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Ошибка: не найден компилятор swiftc. Установите Command Line Tools: xcode-select --install" >&2
    exit 1
fi

SRC_FILES=(
    "${SCRIPT_DIR}/src/NetworkBypass.swift"
    "${SCRIPT_DIR}/src/ObitPortalClient.swift"
    "${SCRIPT_DIR}/src/MonitorEngine.swift"
    "${SCRIPT_DIR}/src/AppDelegate.swift"
    "${SCRIPT_DIR}/src/main.swift"
)

rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${SCRIPT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

FRAMEWORKS=(-framework AppKit -framework Foundation -framework Network -framework Security -framework SystemConfiguration -framework UserNotifications)

echo "[1/3] Компиляция ${APP_NAME}..."
if swiftc -O -target arm64-apple-macosx11.0 "${SRC_FILES[@]}" "${FRAMEWORKS[@]}" -o "${APP_DIR}/Contents/MacOS/ObitAutoAuth-arm64" 2>/dev/null && \
   swiftc -O -target x86_64-apple-macosx11.0 "${SRC_FILES[@]}" "${FRAMEWORKS[@]}" -o "${APP_DIR}/Contents/MacOS/ObitAutoAuth-x86_64" 2>/dev/null; then
    lipo -create \
        "${APP_DIR}/Contents/MacOS/ObitAutoAuth-arm64" \
        "${APP_DIR}/Contents/MacOS/ObitAutoAuth-x86_64" \
        -output "${APP_DIR}/Contents/MacOS/ObitAutoAuth"
    rm -f "${APP_DIR}/Contents/MacOS/ObitAutoAuth-arm64" "${APP_DIR}/Contents/MacOS/ObitAutoAuth-x86_64"
else
    rm -f "${APP_DIR}/Contents/MacOS/ObitAutoAuth-arm64" "${APP_DIR}/Contents/MacOS/ObitAutoAuth-x86_64"
    swiftc -O "${SRC_FILES[@]}" "${FRAMEWORKS[@]}" -o "${APP_DIR}/Contents/MacOS/ObitAutoAuth"
fi

echo "[2/3] Подпись бандла (ad-hoc)..."
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "[3/3] Упаковка ${OUT_ZIP}..."
rm -f "$OUT_ZIP"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
PKG_DIR="${STAGE_DIR}/OBIT-AutoAuth-macOS"
mkdir -p "$PKG_DIR"
cp -R "$APP_DIR" "${PKG_DIR}/${APP_NAME}"
cp "${SCRIPT_DIR}/Install.command" "${PKG_DIR}/Install.command"
cp "${SCRIPT_DIR}/Uninstall.command" "${PKG_DIR}/Uninstall.command"
cp "${SCRIPT_DIR}/README.txt" "${PKG_DIR}/README.txt"
chmod +x "${PKG_DIR}/Install.command" "${PKG_DIR}/Uninstall.command"

ditto -c -k --sequesterRsrc --keepParent "$PKG_DIR" "$OUT_ZIP"
echo "Готово: ${OUT_ZIP}"
