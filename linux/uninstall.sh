#!/usr/bin/env bash
set -euo pipefail

HELPER_PATH="/usr/local/libexec/obit-net-bypass"
CLI_PATH="/usr/local/bin/obit-auth"
TRAY_BIN_PATH="/usr/local/bin/obit-auth-tray"
LIB_DIR="/usr/local/lib/obit-auto-auth"
SUDOERS_PATH="/etc/sudoers.d/obit-auto-auth"
UNIT_PATH="${HOME}/.config/systemd/user/obit-auto-auth.service"
AUTOSTART_PATH="${HOME}/.config/autostart/obit-auto-auth-tray.desktop"
APP_DESKTOP_PATH="${HOME}/.local/share/applications/obit-auto-auth-tray.desktop"
OBIT_USER="_obitauth"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Запускайте uninstall.sh от обычного пользователя." >&2
    exit 1
fi

echo "[1/4] Остановка и удаление systemd --user сервиса и трея..."
pkill -f "obit_auth\.tray" 2>/dev/null || true
rm -f "$AUTOSTART_PATH" "$APP_DESKTOP_PATH" "${HOME}/.local/share/icons/hicolor/scalable/apps/obit-auto-auth.svg"
systemctl --user disable --now obit-auto-auth.service 2>/dev/null || true
rm -f "$UNIT_PATH"
systemctl --user daemon-reload || true

echo "[2/4] Очистка правил ip rule / таблицы 1337..."
if [[ -x "$HELPER_PATH" ]]; then
    sudo "$HELPER_PATH" --cleanup || true
fi

echo "[3/4] Удаление системных файлов и правила sudoers..."
sudo rm -f "$SUDOERS_PATH" "$HELPER_PATH" "$CLI_PATH" "$TRAY_BIN_PATH"
sudo rm -rf "$LIB_DIR"

echo "[4/4] Удаление системного пользователя ${OBIT_USER}..."
if id -u "$OBIT_USER" >/dev/null 2>&1; then
    sudo userdel "$OBIT_USER" || true
fi

echo "Удаление завершено. Конфиг ~/.config/obit-auto-auth/config.toml сохранён."
