#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
OUT_ZIP="${DIST_DIR}/OBIT-AutoAuth-Windows.zip"

python3 - "${SCRIPT_DIR}" <<'PY'
import sys
from pathlib import Path

win_dir = Path(sys.argv[1])
for name in ("Install.bat", "Uninstall.bat", "README.txt"):
    p = win_dir / name
    text = p.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\n", "\r\n")
    p.write_bytes(text.encode("utf-8"))
PY

mkdir -p "$DIST_DIR"
rm -f "$OUT_ZIP"
(cd "$SCRIPT_DIR" && zip -r "$OUT_ZIP" Install.bat Uninstall.bat README.txt Resources/app.ico src/NetworkBypass.cs src/ObitPortalClient.cs src/MonitorEngine.cs src/TrayApp.cs)
unzip -l "$OUT_ZIP"
