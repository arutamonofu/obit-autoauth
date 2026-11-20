#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
PKG_NAME="OBIT-AutoAuth-Linux"
OUT_TAR="${DIST_DIR}/${PKG_NAME}.tar.gz"

mkdir -p "$DIST_DIR"
rm -f "$OUT_TAR"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
PKG_DIR="${STAGE_DIR}/${PKG_NAME}"
mkdir -p "${PKG_DIR}/src" "${PKG_DIR}/scripts" "${PKG_DIR}/systemd" "${PKG_DIR}/assets"

cp "${SCRIPT_DIR}/install.sh" "${PKG_DIR}/install.sh"
cp "${SCRIPT_DIR}/uninstall.sh" "${PKG_DIR}/uninstall.sh"
cp "${SCRIPT_DIR}/README.txt" "${PKG_DIR}/README.txt"
cp "${SCRIPT_DIR}/config.example.toml" "${PKG_DIR}/config.example.toml"
cp "${SCRIPT_DIR}/assets/obit-auto-auth.svg" "${PKG_DIR}/assets/obit-auto-auth.svg"
cp "${SCRIPT_DIR}/scripts/obit-auth" "${PKG_DIR}/scripts/obit-auth"
cp "${SCRIPT_DIR}/scripts/obit-auth-tray" "${PKG_DIR}/scripts/obit-auth-tray"
cp "${SCRIPT_DIR}/scripts/obit-net-bypass" "${PKG_DIR}/scripts/obit-net-bypass"
cp "${SCRIPT_DIR}/systemd/obit-auto-auth.service" "${PKG_DIR}/systemd/obit-auto-auth.service"
cp -R "${SCRIPT_DIR}/src/obit_auth" "${PKG_DIR}/src/obit_auth"
rm -rf "${PKG_DIR}/src/obit_auth/__pycache__"

chmod +x "${PKG_DIR}/install.sh" "${PKG_DIR}/uninstall.sh" \
    "${PKG_DIR}/scripts/obit-auth" "${PKG_DIR}/scripts/obit-auth-tray" "${PKG_DIR}/scripts/obit-net-bypass"

tar -czf "$OUT_TAR" -C "$STAGE_DIR" "$PKG_NAME"
tar -tzf "$OUT_TAR"
echo "Готово: ${OUT_TAR}"
