"""Configuration loader for the OBIT Wi-Fi auto-authorization daemon."""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

from obit_auth.portal_client import DEFAULT_PROBE_URL

DEFAULT_CONFIG_PATH = Path.home() / ".config" / "obit-auto-auth" / "config.toml"
DEFAULT_BYPASS_HELPER = "/usr/local/libexec/obit-net-bypass"


@dataclass
class DaemonConfig:
    check_interval_sec: int = 15
    retry_cooldown_sec: int = 30
    ssid_filter: str = ""
    probe_url: str = DEFAULT_PROBE_URL
    bypass_helper: str = DEFAULT_BYPASS_HELPER
    use_sudo_bypass: bool = True
    notify_on_success: bool = True
    notify_on_failure: bool = True
    vpn_wait_sec: float = 4.0

    @classmethod
    def load(cls, path: Path) -> "DaemonConfig":
        if not path.exists():
            return cls()
        with path.open("rb") as fh:
            data = tomllib.load(fh)

        vpn_wait = data.get("vpn_wait_sec")
        if vpn_wait is None and isinstance(data.get("vpn"), dict):
            vpn_wait = data["vpn"].get("reconnect_wait_sec", 4.0)

        return cls(
            check_interval_sec=int(data.get("check_interval_sec", 15)),
            retry_cooldown_sec=int(data.get("retry_cooldown_sec", 30)),
            ssid_filter=str(data.get("ssid_filter", "")),
            probe_url=str(data.get("probe_url", DEFAULT_PROBE_URL)),
            bypass_helper=str(data.get("bypass_helper", DEFAULT_BYPASS_HELPER)),
            use_sudo_bypass=bool(data.get("use_sudo_bypass", True)),
            notify_on_success=bool(data.get("notify_on_success", True)),
            notify_on_failure=bool(data.get("notify_on_failure", True)),
            vpn_wait_sec=float(vpn_wait if vpn_wait is not None else 4.0),
        )


def set_notifications_enabled(path: Path, enabled: bool) -> None:
    """Update notify_on_success and notify_on_failure in config.toml."""
    val = "true" if enabled else "false"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(
            f"notify_on_success = {val}\nnotify_on_failure = {val}\n",
            encoding="utf-8",
        )
        return

    text = path.read_text(encoding="utf-8")
    for key in ("notify_on_success", "notify_on_failure"):
        pattern = re.compile(rf"^(\s*{key}\s*=\s*)(?:true|false)(.*)$", re.MULTILINE)
        if pattern.search(text):
            text = pattern.sub(rf"\g<1>{val}\g<2>", text, count=1)
        else:
            if text and not text.endswith("\n"):
                text += "\n"
            text += f"{key} = {val}\n"
    path.write_text(text, encoding="utf-8")
