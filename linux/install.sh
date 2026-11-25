#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

LIB_DIR="/usr/local/lib/obit-auto-auth"
HELPER_PATH="/usr/local/libexec/obit-net-bypass"
CLI_PATH="/usr/local/bin/obit-auth"
TRAY_BIN_PATH="/usr/local/bin/obit-auth-tray"
SUDOERS_PATH="/etc/sudoers.d/obit-auto-auth"
OBIT_USER="_obitauth"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Запускайте install.sh от обычного пользователя (скрипт сам запросит sudo)." >&2
    exit 1
fi

check_dependencies() {
    local missing=()
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v nmcli >/dev/null 2>&1 || missing+=("network-manager (nmcli)")
    command -v notify-send >/dev/null 2>&1 || missing+=("libnotify-bin (notify-send)")
    command -v systemctl >/dev/null 2>&1 || missing+=("systemd")

    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import sys; assert sys.version_info >= (3, 11)" 2>/dev/null; then
            echo "Требуется Python 3.11 или новее." >&2
            exit 1
        fi
        if ! python3 -c "import gi; gi.require_version('Gtk', '3.0')" 2>/dev/null; then
            missing+=("python3-gi / gir1.2-gtk-3.0")
        fi
        if ! python3 -c "import gi; gi.require_version('AyatanaAppIndicator3', '0.1')" 2>/dev/null && \
           ! python3 -c "import gi; gi.require_version('AppIndicator3', '0.1')" 2>/dev/null; then
            missing+=("gir1.2-ayatanaappindicator3-0.1")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Не найдены обязательные зависимости:" >&2
        for dep in "${missing[@]}"; do
            echo "  - $dep" >&2
        done
        echo "Установите их (например, на Ubuntu/Debian):" >&2
        echo "  sudo apt install python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 network-manager libnotify-bin" >&2
        exit 1
    fi
}

check_dependencies

echo "[1/6] Создание системного пользователя ${OBIT_USER} (если отсутствует)..."
if ! id -u "$OBIT_USER" >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$OBIT_USER"
fi

echo "[2/6] Установка библиотеки obit_auth в ${LIB_DIR}..."
sudo mkdir -p "$LIB_DIR"
sudo rm -rf "${LIB_DIR}/obit_auth"
sudo cp -r "${REPO_DIR}/src/obit_auth" "${LIB_DIR}/obit_auth"
sudo chmod -R a+rX "$LIB_DIR"

echo "[3/6] Установка helper'а ${HELPER_PATH}, CLI ${CLI_PATH}, трея ${TRAY_BIN_PATH} и правила sudoers..."
sudo mkdir -p /usr/local/libexec /usr/local/bin
sudo install -m 0755 -o root -g root "${REPO_DIR}/scripts/obit-net-bypass" "$HELPER_PATH"
sudo install -m 0755 -o root -g root "${REPO_DIR}/scripts/obit-auth" "$CLI_PATH"
sudo install -m 0755 -o root -g root "${REPO_DIR}/scripts/obit-auth-tray" "$TRAY_BIN_PATH"

TMP_SUDOERS="$(mktemp)"
cat >"$TMP_SUDOERS" <<EOF
Defaults!${HELPER_PATH} !syslog, !pam_session
${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_PATH} *
EOF
if ! sudo visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    cat >"$TMP_SUDOERS" <<EOF
${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_PATH} *
EOF
    sudo visudo -cf "$TMP_SUDOERS" >/dev/null
fi
sudo install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_PATH"
rm -f "$TMP_SUDOERS"

echo "[4/6] Установка конфигурации пользователя..."
CFG_DIR="${TARGET_HOME}/.config/obit-auto-auth"
mkdir -p "$CFG_DIR"
if [[ ! -f "${CFG_DIR}/config.toml" ]]; then
    cp "${REPO_DIR}/config.example.toml" "${CFG_DIR}/config.toml"
    echo "Создан конфиг: ${CFG_DIR}/config.toml"
else
    echo "Конфиг уже существует: ${CFG_DIR}/config.toml"
fi

echo "[5/6] Обновление и перезапуск systemd --user сервиса..."
UNIT_DIR="${TARGET_HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cp "${REPO_DIR}/systemd/obit-auto-auth.service" "${UNIT_DIR}/obit-auto-auth.service"
systemctl --user daemon-reload
systemctl --user enable obit-auto-auth.service
systemctl --user restart obit-auto-auth.service

echo "[6/6] Настройка автозапуска иконки в трее..."
AUTOSTART_DIR="${TARGET_HOME}/.config/autostart"
APPS_DIR="${TARGET_HOME}/.local/share/applications"
ICON_DIR="${TARGET_HOME}/.local/share/icons/hicolor/scalable/apps"
mkdir -p "$AUTOSTART_DIR" "$APPS_DIR" "$ICON_DIR"
if [[ -f "${REPO_DIR}/assets/obit-auto-auth.svg" ]]; then
    cp "${REPO_DIR}/assets/obit-auto-auth.svg" "${ICON_DIR}/obit-auto-auth.svg"
    if [[ ! -f "${TARGET_HOME}/.local/share/icons/hicolor/index.theme" && -f /usr/share/icons/hicolor/index.theme ]]; then
        cp /usr/share/icons/hicolor/index.theme "${TARGET_HOME}/.local/share/icons/hicolor/index.theme"
    fi
    gtk-update-icon-cache -f -t "${TARGET_HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi
DESKTOP_CONTENT="[Desktop Entry]
Type=Application
Name=OBIT Wi-Fi Auto-Auth
Comment=Индикатор автоавторизации Wi-Fi ОБИТ
Exec=${TRAY_BIN_PATH}
Icon=obit-auto-auth
Terminal=false
Categories=Network;Utility;
X-GNOME-Autostart-enabled=true"
printf '%s\n' "$DESKTOP_CONTENT" > "${AUTOSTART_DIR}/obit-auto-auth-tray.desktop"
printf '%s\n' "$DESKTOP_CONTENT" > "${APPS_DIR}/obit-auto-auth-tray.desktop"
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

pkill -f "obit_auth\.tray" 2>/dev/null || true
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    nohup "$TRAY_BIN_PATH" >/dev/null 2>&1 &
fi

echo "Готово! Доступна команда: obit-auth {status|now|logs|restart|tray}"
