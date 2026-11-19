"""System tray indicator for OBIT Wi-Fi auto-authorization daemon on Linux."""

from __future__ import annotations

import argparse
import fcntl
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import IO, Sequence

from obit_auth.config import DEFAULT_CONFIG_PATH, DaemonConfig, set_notifications_enabled
from obit_auth.daemon import notify
from obit_auth.state import (
    DaemonState,
    get_runtime_dir,
    get_state_path,
    get_tray_lock_path,
    is_pid_alive,
    read_state,
)

DEFAULT_AUTOSTART_PATH = Path.home() / ".config" / "autostart" / "obit-auto-auth-tray.desktop"
DEFAULT_TRAY_EXEC = "/usr/local/bin/obit-auth-tray"

ICON_COLORS: dict[str, str] = {
    "gray": "#808080",
    "green": "#32CD32",
    "orange": "#FFA500",
    "red": "#DC143C",
}


def format_tray_presentation(state: DaemonState | None, daemon_alive: bool) -> tuple[str, str, bool]:
    """Return (icon_key, status_text, show_portal_action) for a daemon state."""
    if not daemon_alive or state is None or state.status == "stopped":
        return ("gray", "Автозащита остановлена", False)

    st = state.status
    if st in {"starting", "checking"}:
        return ("gray", "Проверка подключения...", False)
    if st in {"online", "auth_success"}:
        label = (
            "Интернет работает"
            if state.auth_count <= 0
            else f"Интернет работает (входов: {state.auth_count})"
        )
        return ("green", label, False)
    if st == "wifi_disconnected":
        return ("gray", "Wi-Fi не подключён", False)
    if st == "ssid_filtered":
        label = f"Другая сеть Wi-Fi ({state.ssid})" if state.ssid else "Другая сеть Wi-Fi"
        return ("gray", label, False)
    if st == "vpn_stalled":
        return ("orange", "Wi-Fi работает, проверьте VPN", False)
    if st == "manual_required":
        return ("red", "Нужен вход вручную (телефон/SMS)", bool(state.portal_url))
    if st == "unknown_portal":
        return ("orange", "Нужен вход в эту сеть Wi-Fi", bool(state.portal_url))
    return ("orange", "Нет доступа в интернет", False)


def render_dot_svg(fill_hex: str) -> str:
    """Render a 16x16 SVG dot icon matching the Windows tray indicator."""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n'
        '  <circle cx="8" cy="8" r="7" fill="#282828"/>\n'
        f'  <circle cx="8" cy="8" r="6" fill="{fill_hex}"/>\n'
        "</svg>\n"
    )


def ensure_tray_icons(icons_dir: Path) -> Path:
    """Write SVG tray icons into icons_dir and return the directory path."""
    icons_dir.mkdir(parents=True, exist_ok=True)
    for key, color in ICON_COLORS.items():
        icon_file = icons_dir / f"obit-tray-{key}.svg"
        content = render_dot_svg(color)
        if not icon_file.exists() or icon_file.read_text(encoding="utf-8") != content:
            icon_file.write_text(content, encoding="utf-8")
    return icons_dir


def is_autostart_enabled(desktop_path: Path = DEFAULT_AUTOSTART_PATH) -> bool:
    """Return True if XDG autostart .desktop entry exists and is not Hidden=true."""
    if not desktop_path.exists():
        return False
    try:
        for line in desktop_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip().lower()
            if stripped == "hidden=true" or stripped == "x-gnome-autostart-enabled=false":
                return False
    except OSError:
        return False
    return True


def set_autostart_enabled(
    enabled: bool,
    desktop_path: Path = DEFAULT_AUTOSTART_PATH,
    exec_cmd: str = DEFAULT_TRAY_EXEC,
) -> None:
    """Enable or disable XDG autostart for the tray app."""
    if not enabled:
        try:
            desktop_path.unlink(missing_ok=True)
        except OSError:
            pass
        return

    desktop_path.parent.mkdir(parents=True, exist_ok=True)
    desktop_path.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=OBIT Wi-Fi Auto-Auth\n"
        "Comment=Автоматический вход в Wi-Fi ОБИТ\n"
        f"Exec={exec_cmd}\n"
        "Icon=network-wireless\n"
        "Terminal=false\n"
        "Categories=Network;Utility;\n"
        "X-GNOME-Autostart-enabled=true\n",
        encoding="utf-8",
    )


def acquire_single_instance_lock(lock_path: Path | None = None) -> IO[str] | None:
    """Acquire non-blocking exclusive lock; return file handle or None if already running."""
    target = lock_path or get_tray_lock_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    fh = target.open("w", encoding="utf-8")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    fh.write(str(os.getpid()))
    fh.flush()
    return fh


def _load_gtk_and_indicator():
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, GLib, Gtk

    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator
    except (ValueError, ImportError):
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator

    return Gtk, GLib, Gio, AppIndicator


class TrayApp:
    """GTK3 + AppIndicator3 system tray client for obit-auto-auth."""

    def __init__(self, config_path: Path) -> None:
        self.Gtk, self.GLib, self.Gio, self.AppIndicator = _load_gtk_and_indicator()
        self.config_path = config_path
        self.state_path = get_state_path()
        self.icons_dir = ensure_tray_icons(get_runtime_dir() / "icons")
        self._updating_ui = False
        self._last_portal_url = ""
        self._log_window = None
        self._log_buffer = None
        self._log_view = None

        self._ensure_daemon_running()

        self.indicator = self.AppIndicator.Indicator.new(
            "obit-auto-auth",
            "obit-tray-gray",
            self.AppIndicator.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_icon_theme_path(str(self.icons_dir))
        self.indicator.set_status(self.AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("OBIT Wi-Fi Auto-Auth")

        self.menu = self.Gtk.Menu()

        self.status_item = self.Gtk.MenuItem(label="Проверка подключения...")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)

        self.menu.append(self.Gtk.SeparatorMenuItem())

        self.portal_item = self.Gtk.MenuItem(label="Открыть страницу входа")
        self.portal_item.connect("activate", self._on_open_portal)
        self.menu.append(self.portal_item)

        self.check_now_item = self.Gtk.MenuItem(label="Проверить и войти сейчас")
        self.check_now_item.connect("activate", self._on_check_now)
        self.menu.append(self.check_now_item)

        self.menu.append(self.Gtk.SeparatorMenuItem())

        self.autostart_item = self.Gtk.CheckMenuItem(label="Запускать автоматически")
        self.autostart_item.connect("toggled", self._on_toggle_autostart)
        self.menu.append(self.autostart_item)

        self.notify_item = self.Gtk.CheckMenuItem(label="Показывать уведомления")
        self.notify_item.connect("toggled", self._on_toggle_notify)
        self.menu.append(self.notify_item)

        self.open_log_item = self.Gtk.MenuItem(label="Открыть журнал работы")
        self.open_log_item.connect("activate", self._on_open_log)
        self.menu.append(self.open_log_item)

        self.menu.append(self.Gtk.SeparatorMenuItem())

        self.exit_item = self.Gtk.MenuItem(label="Выход")
        self.exit_item.connect("activate", self._on_exit)
        self.menu.append(self.exit_item)

        self.menu.show_all()
        self.portal_item.hide()
        self.indicator.set_menu(self.menu)

        self._setup_file_monitor()
        self._refresh_state()
        self.GLib.timeout_add_seconds(2, self._on_poll_tick)

    def _ensure_daemon_running(self) -> None:
        state = read_state(self.state_path)
        if not self._is_daemon_alive(state):
            subprocess.Popen(
                ["systemctl", "--user", "start", "obit-auto-auth.service"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    def _setup_file_monitor(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        gfile = self.Gio.File.new_for_path(str(self.state_path))
        self._monitor = gfile.monitor_file(self.Gio.FileMonitorFlags.NONE, None)
        self._monitor.connect("changed", self._on_state_file_changed)

    def _on_state_file_changed(self, *_args: object) -> None:
        self._refresh_state()

    def _on_poll_tick(self) -> bool:
        self._refresh_state()
        return True

    def _is_daemon_alive(self, state: DaemonState | None) -> bool:
        if state is not None and state.status != "stopped" and is_pid_alive(state.pid):
            return True
        return False

    def _refresh_state(self) -> None:
        state = read_state(self.state_path)
        alive = self._is_daemon_alive(state)
        icon_key, status_text, show_portal = format_tray_presentation(state, alive)

        self.status_item.set_label(status_text)
        self.indicator.set_icon_full(f"obit-tray-{icon_key}", status_text)

        self._last_portal_url = state.portal_url if (state and show_portal) else ""
        if self._last_portal_url:
            self.portal_item.show()
        else:
            self.portal_item.hide()

        self._updating_ui = True
        try:
            self.autostart_item.set_active(is_autostart_enabled())
            cfg = DaemonConfig.load(self.config_path)
            self.notify_item.set_active(cfg.notify_on_success or cfg.notify_on_failure)
        finally:
            self._updating_ui = False

    def _on_open_portal(self, _item: object) -> None:
        if self._last_portal_url:
            subprocess.Popen(
                ["xdg-open", self._last_portal_url],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    def _on_check_now(self, _item: object) -> None:
        self.status_item.set_label("Проверка подключения...")
        self.indicator.set_icon_full("obit-tray-gray", "Проверка подключения...")
        state = read_state(self.state_path)
        if state is not None and state.status != "stopped" and is_pid_alive(state.pid):
            try:
                os.kill(state.pid, signal.SIGUSR1)
                return
            except OSError:
                pass
        subprocess.Popen(
            ["systemctl", "--user", "start", "obit-auto-auth.service"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _on_toggle_autostart(self, item: object) -> None:
        if self._updating_ui:
            return
        set_autostart_enabled(bool(item.get_active()))

    def _on_toggle_notify(self, item: object) -> None:
        if self._updating_ui:
            return
        enabled = bool(item.get_active())
        set_notifications_enabled(self.config_path, enabled)
        state = read_state(self.state_path)
        if state is not None and state.status != "stopped" and is_pid_alive(state.pid):
            try:
                os.kill(state.pid, signal.SIGHUP)
            except OSError:
                pass

    def _fetch_logs_text(self) -> str:
        try:
            out = subprocess.check_output(
                ["journalctl", "--user", "-u", "obit-auto-auth.service", "-n", "200", "--no-pager"],
                text=True,
                stderr=subprocess.STDOUT,
                timeout=5,
            )
            return out or "(журнал пуст)"
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            return f"Не удалось прочитать журнал: {exc}"

    def _reload_log_window(self, *_args: object) -> None:
        if self._log_buffer is None or self._log_view is None:
            return
        text = self._fetch_logs_text()
        self._log_buffer.set_text(text)
        end_iter = self._log_buffer.get_end_iter()
        self._log_view.scroll_to_iter(end_iter, 0.0, False, 0.0, 1.0)

    def _on_open_log(self, _item: object) -> None:
        if self._log_window is not None:
            self._reload_log_window()
            self._log_window.present()
            return

        win = self.Gtk.Window(title="OBIT Auto-Auth — Журнал работы")
        win.set_default_size(780, 480)

        vbox = self.Gtk.Box(orientation=self.Gtk.Orientation.VERTICAL, spacing=6)
        vbox.set_border_width(8)
        win.add(vbox)

        scrolled = self.Gtk.ScrolledWindow()
        scrolled.set_hexpand(True)
        scrolled.set_vexpand(True)
        vbox.pack_start(scrolled, True, True, 0)

        textview = self.Gtk.TextView()
        textview.set_editable(False)
        textview.set_cursor_visible(False)
        textview.set_monospace(True)
        textview.set_wrap_mode(self.Gtk.WrapMode.WORD_CHAR)
        scrolled.add(textview)

        btn_box = self.Gtk.Box(orientation=self.Gtk.Orientation.HORIZONTAL, spacing=6)
        btn_box.set_halign(self.Gtk.Align.END)
        vbox.pack_start(btn_box, False, False, 0)

        refresh_btn = self.Gtk.Button(label="Обновить")
        refresh_btn.connect("clicked", self._reload_log_window)
        btn_box.pack_start(refresh_btn, False, False, 0)

        close_btn = self.Gtk.Button(label="Закрыть")
        close_btn.connect("clicked", lambda *_: win.destroy())
        btn_box.pack_start(close_btn, False, False, 0)

        def _on_destroy(*_args: object) -> None:
            self._log_window = None
            self._log_buffer = None
            self._log_view = None

        win.connect("destroy", _on_destroy)
        self._log_window = win
        self._log_buffer = textview.get_buffer()
        self._log_view = textview

        win.show_all()
        self._reload_log_window()

    def _on_exit(self, _item: object) -> None:
        subprocess.run(
            ["systemctl", "--user", "stop", "obit-auto-auth.service"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        self.Gtk.main_quit()

    def run(self) -> int:
        self.GLib.unix_signal_add(self.GLib.PRIORITY_DEFAULT, signal.SIGINT, self._on_unix_quit)
        self.GLib.unix_signal_add(self.GLib.PRIORITY_DEFAULT, signal.SIGTERM, self._on_unix_quit)
        self.Gtk.main()
        return 0

    def _on_unix_quit(self) -> bool:
        self.Gtk.main_quit()
        return False


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="OBIT Wi-Fi auto-auth system tray indicator")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    args = parser.parse_args(argv)

    lock_fh = acquire_single_instance_lock()
    if lock_fh is None:
        notify("OBIT Wi-Fi Auto-Auth", "Программа уже запущена.")
        state = read_state()
        if state is not None and state.status != "stopped" and is_pid_alive(state.pid):
            try:
                os.kill(state.pid, signal.SIGUSR1)
            except OSError:
                pass
        return 0

    try:
        app = TrayApp(config_path=args.config)
        return app.run()
    finally:
        lock_fh.close()


if __name__ == "__main__":
    sys.exit(main())
