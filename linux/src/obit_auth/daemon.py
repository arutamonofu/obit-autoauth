"""Background monitor daemon for OBIT Wi-Fi captive portal auto-authorization."""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from obit_auth.config import DEFAULT_CONFIG_PATH, DaemonConfig
from obit_auth.connectivity import check_default_route_online, wait_for_default_route
from obit_auth.portal_client import PortalClient
from obit_auth.state import DaemonState, write_state

LOG = logging.getLogger("obit_auth")


def notify(title: str, body: str, urgency: str = "normal") -> None:
    try:
        subprocess.run(
            ["notify-send", "-a", "OBIT Auto-Auth", "-u", urgency, title, body],
            check=False,
            timeout=5,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        LOG.debug("notify-send unavailable: %s - %s", title, body)


def active_wifi_connection() -> str | None:
    """Return active Wi-Fi connection/SSID name via nmcli, or None if disconnected/unavailable."""
    try:
        out = subprocess.check_output(
            ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "dev"],
            text=True,
            timeout=4,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return None

    for line in out.splitlines():
        parts = line.split(":", 2)
        if len(parts) == 3 and parts[0] == "wifi" and parts[1] == "connected":
            return parts[2]
    return None


def run_portal_check(cfg: DaemonConfig, probe_only: bool = False) -> dict[str, object]:
    """Execute portal probe/authorization via bypass helper or directly."""
    if cfg.use_sudo_bypass and Path(cfg.bypass_helper).exists():
        flag = "--probe" if probe_only else "--authorize"
        cmd = ["sudo", "-n", cfg.bypass_helper, flag, "--probe-url", cfg.probe_url]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        lines = proc.stdout.strip().splitlines()
        if lines:
            try:
                return json.loads(lines[-1])
            except json.JSONDecodeError:
                pass
        return {
            "status": "bypass_error",
            "portal_url": "",
            "message": proc.stderr.strip() or f"Helper exited with {proc.returncode}",
        }

    client = PortalClient(probe_url=cfg.probe_url)
    if probe_only:
        payload = asdict(client.probe())
        payload.pop("body", None)
        return payload
    return asdict(client.authorize_if_needed())


class MonitorDaemon:
    """Fast-path first monitor loop: zero subprocesses while internet is healthy."""

    def __init__(self, cfg: DaemonConfig) -> None:
        self.cfg = cfg
        self._last_alert_key: str = ""
        self._last_alert_ts: float = 0.0
        self._last_ssid: str | None = None
        self._fail_streak: int = 0
        self._auth_count: int = 0
        self._last_portal_url: str = ""
        self._last_message: str = ""
        self._last_status: str = "checking"

    def snapshot(self, status_override: str | None = None) -> DaemonState:
        return DaemonState(
            status=status_override or self._last_status,
            auth_count=self._auth_count,
            portal_url=self._last_portal_url,
            message=self._last_message,
            ssid=self._last_ssid or "",
            fail_streak=self._fail_streak,
            pid=os.getpid(),
            updated_at=time.time(),
        )

    def _alert_once(self, key: str, title: str, body: str, urgency: str = "critical") -> None:
        now = time.monotonic()
        cooldown = max(300, self.cfg.retry_cooldown_sec * 10)
        if key == self._last_alert_key and (now - self._last_alert_ts) < cooldown:
            return
        self._last_alert_key = key
        self._last_alert_ts = now
        notify(title, body, urgency=urgency)

    def _reset_health(self) -> None:
        if self._fail_streak > 0 or self._last_alert_key:
            LOG.info("Connectivity restored (streak was %d)", self._fail_streak)
        self._fail_streak = 0
        self._last_alert_key = ""

    def step(self, force_bypass: bool = False, manual_trigger: bool = False) -> str:
        # 1. Fast path: pure-Python IPv4 HTTP probe via current default route (0 subprocesses)
        if not force_bypass and check_default_route_online(url=self.cfg.probe_url, timeout=2.5):
            self._reset_health()
            self._last_portal_url = ""
            self._last_message = ""
            self._last_status = "online"
            if manual_trigger:
                notify("Авторизация активна", "Повторный вход не требуется.")
            return "online"

        # 2. Slow path: verify Wi-Fi is actually connected before running sudo bypass
        ssid = active_wifi_connection()
        if ssid is None:
            self._last_ssid = None
            self._fail_streak = 0
            self._last_portal_url = ""
            self._last_message = ""
            self._last_status = "wifi_disconnected"
            if manual_trigger:
                notify("Wi-Fi не подключён", "Подключитесь к сети Wi-Fi и повторите проверку.")
            return "wifi_disconnected"

        if ssid != self._last_ssid:
            self._last_alert_key = ""
            self._fail_streak = 0
            self._last_ssid = ssid

        if self.cfg.ssid_filter and ssid and ssid != self.cfg.ssid_filter:
            self._last_portal_url = ""
            self._last_message = ""
            self._last_status = "ssid_filtered"
            if manual_trigger:
                notify("Другая сеть Wi-Fi", f"Сеть «{ssid}» пропущена фильтром в настройках.")
            return "ssid_filtered"

        self._fail_streak += 1
        t0 = time.monotonic()
        LOG.info("Fast probe failed on Wi-Fi '%s' (attempt %d); checking portal via bypass...", ssid, self._fail_streak)
        res = run_portal_check(self.cfg)
        elapsed = time.monotonic() - t0

        status = str(res.get("status", "unknown"))
        portal_url = str(res.get("portal_url", ""))
        message = str(res.get("message", ""))

        if status == "auth_success":
            vpn_ok = wait_for_default_route(url=self.cfg.probe_url, timeout_sec=self.cfg.vpn_wait_sec)
            LOG.info(
                "OBIT Wi-Fi re-authorized in %.2fs (vpn_online=%s, portal=%s)",
                elapsed,
                vpn_ok,
                portal_url,
            )
            self._reset_health()
            self._auth_count += 1
            self._last_portal_url = ""
            self._last_message = ""
            self._last_status = "auth_success"
            if manual_trigger or self.cfg.notify_on_success:
                body = (
                    f"Повторный вход занял {elapsed:.1f} с."
                    if vpn_ok
                    else f"Вход занял {elapsed:.1f} с, но сеть или VPN пока не отвечают."
                )
                notify("Вход в ОБИТ выполнен", body)
            return "auth_success"

        if status == "already_online":
            if check_default_route_online(url=self.cfg.probe_url, timeout=2.0):
                self._reset_health()
                self._last_portal_url = ""
                self._last_message = ""
                self._last_status = "online"
                if manual_trigger:
                    notify("Авторизация активна", "Повторный вход не требуется.")
                return "online"
            LOG.warning("Wi-Fi '%s' is online via bypass, but default route (VPN) is stalled", ssid)
            self._last_portal_url = ""
            self._last_message = ""
            self._last_status = "vpn_stalled"
            if manual_trigger:
                notify(
                    "Вход есть, но сеть не отвечает",
                    "Авторизация активна. Проверьте сеть или перезапустите VPN.",
                    urgency="critical",
                )
            elif self._fail_streak >= 2 and self.cfg.notify_on_failure:
                self._alert_once(
                    "vpn_stalled",
                    "Вход есть, но сеть не отвечает",
                    "Авторизация активна. Проверьте сеть или перезапустите VPN.",
                )
            return "vpn_stalled"

        if status == "manual_required":
            LOG.warning("Manual verification required on portal: %s", portal_url)
            self._last_portal_url = portal_url
            self._last_message = message
            self._last_status = "manual_required"
            if manual_trigger:
                notify(
                    "Нужен вход вручную (телефон/SMS)",
                    "Откройте меню значка в трее и нажмите «Открыть страницу входа».",
                    urgency="critical",
                )
            elif self.cfg.notify_on_failure:
                self._alert_once(
                    "manual_required",
                    "Нужен вход вручную (телефон/SMS)",
                    "Откройте меню значка в трее и нажмите «Открыть страницу входа».",
                )
            return "manual_required"

        if status == "unknown_portal":
            LOG.info("Unknown captive portal detected: %s", portal_url)
            self._last_portal_url = portal_url
            self._last_message = message
            self._last_status = "unknown_portal"
            if manual_trigger:
                notify(
                    "Нужен вход в эту сеть Wi-Fi",
                    "Откройте меню значка в трее и нажмите «Открыть страницу входа».",
                )
            elif self.cfg.notify_on_failure:
                self._alert_once(
                    f"unknown:{portal_url}",
                    "Нужен вход в эту сеть Wi-Fi",
                    "Откройте меню значка в трее и нажмите «Открыть страницу входа».",
                    urgency="normal",
                )
            return "unknown_portal"

        LOG.warning("Bypass check failed (%s) in %.2fs: %s", status, elapsed, message)
        self._last_portal_url = portal_url
        self._last_message = message
        self._last_status = status
        title = "Нет связи с сетью" if status == "offline" else "Ошибка авторизации"
        body = (
            "Проверьте подключение к Wi-Fi или роутеру."
            if status == "offline"
            else "Не удалось выполнить вход. Подробности в журнале работы."
        )
        if manual_trigger:
            notify(title, body, urgency="critical")
        elif self._fail_streak >= 2 and self.cfg.notify_on_failure:
            self._alert_once(f"err:{status}", title, body)
        return status


def print_status(cfg: DaemonConfig) -> int:
    ssid = active_wifi_connection()
    default_ok = check_default_route_online(url=cfg.probe_url, timeout=2.5)
    bypass_res = run_portal_check(cfg, probe_only=True)
    print(f"Wi-Fi connection : {ssid or 'disconnected'}")
    print(f"Default/VPN route: {'ONLINE (204)' if default_ok else 'OFFLINE / BLOCKED'}")
    print(f"Wi-Fi bypass     : {bypass_res.get('status')} (HTTP {bypass_res.get('http_status', 0)})")
    if bypass_res.get("final_url"):
        print(f"Probe URL        : {bypass_res.get('final_url')}")
    return 0 if default_ok else 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="OBIT Wi-Fi auto-authorization daemon")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    parser.add_argument("--once", action="store_true", help="Run one check (fast-path + fallback) and exit")
    parser.add_argument("--force-bypass", action="store_true", help="Force bypass check/auth immediately")
    parser.add_argument("--status", action="store_true", help="Print current Wi-Fi, bypass, and VPN status")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    cfg = DaemonConfig.load(args.config)
    if args.status:
        return print_status(cfg)

    daemon = MonitorDaemon(cfg)
    if args.once or args.force_bypass:
        result = daemon.step(force_bypass=args.force_bypass, manual_trigger=args.force_bypass)
        LOG.info("Check result: %s", result)
        return 0 if result in {"online", "auth_success", "wifi_disconnected", "ssid_filtered"} else 1

    stop = False
    force_next = False
    reload_cfg = False
    wake_event = threading.Event()

    def _handle_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True
        wake_event.set()

    def _handle_force(_signum: int, _frame: object) -> None:
        nonlocal force_next
        force_next = True
        wake_event.set()

    def _handle_reload(_signum: int, _frame: object) -> None:
        nonlocal reload_cfg
        reload_cfg = True
        wake_event.set()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)
    signal.signal(signal.SIGUSR1, _handle_force)
    signal.signal(signal.SIGHUP, _handle_reload)

    LOG.info(
        "Started OBIT auto-auth monitor (interval=%ss, ssid_filter=%r)",
        cfg.check_interval_sec,
        cfg.ssid_filter or "*",
    )
    write_state(daemon.snapshot("checking"))
    try:
        while not stop:
            if reload_cfg:
                reload_cfg = False
                try:
                    daemon.cfg = DaemonConfig.load(args.config)
                    LOG.info("Reloaded config from %s", args.config)
                except Exception:
                    LOG.exception("Failed to reload config from %s", args.config)

            do_force = force_next
            force_next = False
            if do_force:
                write_state(daemon.snapshot("checking"))
            try:
                daemon.step(force_bypass=do_force, manual_trigger=do_force)
                write_state(daemon.snapshot())
            except Exception:
                LOG.exception("Unhandled error in monitor step")

            wake_event.clear()
            if not stop and not force_next and not reload_cfg:
                wake_event.wait(timeout=max(1, daemon.cfg.check_interval_sec))
    finally:
        try:
            write_state(daemon.snapshot("stopped"))
        except OSError:
            pass
    LOG.info("Stopped OBIT auto-auth monitor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
