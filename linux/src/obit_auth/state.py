"""Runtime state persistence for daemon <-> tray IPC."""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path


def get_runtime_dir() -> Path:
    """Return per-user runtime directory for state and lock files."""
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR", "").strip()
    if xdg_runtime:
        base = Path(xdg_runtime)
        if base.is_dir() and os.access(base, os.W_OK):
            return base / "obit-auto-auth"
    return Path(tempfile.gettempdir()) / f"obit-auto-auth-{os.getuid()}"


def get_state_path() -> Path:
    return get_runtime_dir() / "state.json"


def get_tray_lock_path() -> Path:
    return get_runtime_dir() / "tray.lock"


@dataclass
class DaemonState:
    status: str = "starting"
    auth_count: int = 0
    portal_url: str = ""
    message: str = ""
    ssid: str = ""
    fail_streak: int = 0
    pid: int = 0
    updated_at: float = 0.0

    @classmethod
    def from_dict(cls, data: dict[str, object]) -> "DaemonState":
        return cls(
            status=str(data.get("status", "unknown")),
            auth_count=int(data.get("auth_count", 0) or 0),
            portal_url=str(data.get("portal_url", "")),
            message=str(data.get("message", "")),
            ssid=str(data.get("ssid", "")),
            fail_streak=int(data.get("fail_streak", 0) or 0),
            pid=int(data.get("pid", 0) or 0),
            updated_at=float(data.get("updated_at", 0.0) or 0.0),
        )


def write_state(state: DaemonState, path: Path | None = None) -> None:
    """Atomically write daemon state to JSON."""
    target = path or get_state_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = asdict(state)
    if not payload["updated_at"]:
        payload["updated_at"] = time.time()
    if not payload["pid"]:
        payload["pid"] = os.getpid()

    fd, tmp_name = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def read_state(path: Path | None = None) -> DaemonState | None:
    """Read daemon state from JSON, returning None if missing or invalid."""
    target = path or get_state_path()
    try:
        raw = target.read_text(encoding="utf-8")
        data = json.loads(raw)
        if isinstance(data, dict):
            return DaemonState.from_dict(data)
    except (OSError, ValueError, TypeError):
        return None
    return None


def is_pid_alive(pid: int) -> bool:
    """Check whether a process with the given PID is currently running."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
