import AppKit
import Foundation
import Network
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let bundleId = "ru.obit.autoauth"
    static let wakeNotificationName = Notification.Name("ru.obit.autoauth.wake")

    private let log = Logger()
    private let settings = AppSettings()
    private lazy var engine = MonitorEngine(
        log: log,
        onStateChanged: { [weak self] presentation in
            self?.applyPresentation(presentation)
        },
        onNotify: { [weak self] req in
            self?.showNotification(key: req.key, title: req.title, text: req.text, force: req.force)
        }
    )

    private var statusBarItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem(title: "Проверка подключения...", action: nil, keyEquivalent: "")
    private let portalMenuItem = NSMenuItem(title: "Открыть страницу входа", action: #selector(onOpenPortalClick), keyEquivalent: "")
    private let checkNowMenuItem = NSMenuItem(title: "Проверить и войти сейчас", action: #selector(onCheckNowClick), keyEquivalent: "")
    private let autostartMenuItem = NSMenuItem(title: "Запускать автоматически", action: #selector(onToggleAutostart), keyEquivalent: "")
    private let notifyMenuItem = NSMenuItem(title: "Показывать уведомления", action: #selector(onToggleNotify), keyEquivalent: "")
    private let openLogMenuItem = NSMenuItem(title: "Открыть журнал работы", action: #selector(onOpenLog), keyEquivalent: "")
    private let exitMenuItem = NSMenuItem(title: "Выход", action: #selector(onExit), keyEquivalent: "q")

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorPrimed = false
    private let checkQueue = DispatchQueue(label: "ru.obit.autoauth.check")
    private let checkingLock = NSLock()
    private var isChecking = false

    private var lastAlertKey = ""
    private var lastAlertDate = Date.distantPast
    private var lastPortalUrl = ""

    private var launchAgentUrl: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppDelegate.bundleId).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotifications()
        setupStatusBar()
        setupMonitors()

        log.info("ObitAutoAuth started")
        if !settings.welcomeShown {
            settings.welcomeShown = true
            showNotification(
                key: "welcome",
                title: "OBIT Wi-Fi Auto-Auth запущен",
                text: "Значок программы находится в строке меню.",
                force: true
            )
        }

        triggerCheckAsync(forceBypass: false, manualTrigger: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pathMonitor?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        log.info("ObitAutoAuth exited")
    }

    private var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func setupNotifications() {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.toolTip = "OBIT Wi-Fi Auto-Auth"

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        portalMenuItem.target = self
        portalMenuItem.isHidden = true
        checkNowMenuItem.target = self
        autostartMenuItem.target = self
        autostartMenuItem.state = isAutostartEnabled() ? .on : .off
        notifyMenuItem.target = self
        notifyMenuItem.state = settings.notificationsEnabled ? .on : .off
        openLogMenuItem.target = self
        exitMenuItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(portalMenuItem)
        menu.addItem(checkNowMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(autostartMenuItem)
        menu.addItem(notifyMenuItem)
        menu.addItem(openLogMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(exitMenuItem)

        statusBarItem.menu = menu
        applyPresentation(MonitorEngine.formatPresentation(status: .checking, authCount: 0, portalUrl: ""))
    }

    private func setupMonitors() {
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.triggerCheckAsync(forceBypass: false, manualTrigger: false)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onSecondInstanceWake),
            name: AppDelegate.wakeNotificationName,
            object: nil
        )

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self = self else { return }
            if !self.pathMonitorPrimed {
                self.pathMonitorPrimed = true
                return
            }
            self.triggerCheckAsync(forceBypass: false, manualTrigger: false)
        }
        monitor.start(queue: DispatchQueue(label: "ru.obit.autoauth.path-watch"))
        pathMonitor = monitor
    }

    private func applyPresentation(_ p: UiPresentation) {
        DispatchQueue.main.async {
            self.lastPortalUrl = p.showPortalAction ? p.portalUrl : ""
            self.portalMenuItem.isHidden = self.lastPortalUrl.isEmpty
            self.statusMenuItem.title = p.statusText
            self.statusBarItem.button?.toolTip = p.statusText
            self.statusBarItem.button?.image = self.renderDotImage(color: self.nsColor(for: p.iconColor))
        }
    }

    private func nsColor(for color: IconColor) -> NSColor {
        switch color {
        case .gray:
            return NSColor(calibratedRed: 0.50, green: 0.50, blue: 0.50, alpha: 1.0)
        case .green:
            return NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.20, alpha: 1.0)
        case .orange:
            return NSColor(calibratedRed: 1.00, green: 0.65, blue: 0.00, alpha: 1.0)
        case .red:
            return NSColor(calibratedRed: 0.86, green: 0.08, blue: 0.24, alpha: 1.0)
        }
    }

    private func renderDotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor(calibratedWhite: 0.16, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()

            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func showNotification(key: String, title: String, text: String, force: Bool) {
        DispatchQueue.main.async {
            guard self.notificationsAvailable else { return }
            if !self.settings.notificationsEnabled && !force {
                return
            }
            let now = Date()
            if !force && key == self.lastAlertKey && now.timeIntervalSince(self.lastAlertDate) < 300 {
                return
            }
            self.lastAlertKey = key
            self.lastAlertDate = now

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            if !self.lastPortalUrl.isEmpty {
                content.userInfo = ["portalUrl": self.lastPortalUrl]
            }

            let req = UNNotificationRequest(
                identifier: "obit-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlStr = response.notification.request.content.userInfo["portalUrl"] as? String {
            openPortalUrl(urlStr)
        } else if !lastPortalUrl.isEmpty {
            openPortalUrl(lastPortalUrl)
        }
        completionHandler()
    }

    private func triggerCheckAsync(forceBypass: Bool, manualTrigger: Bool) {
        checkingLock.lock()
        if isChecking {
            checkingLock.unlock()
            return
        }
        isChecking = true
        checkingLock.unlock()

        checkQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.checkingLock.lock()
                self.isChecking = false
                self.checkingLock.unlock()
            }
            self.engine.runCheckCycle(forceBypass: forceBypass, manualTrigger: manualTrigger)
        }
    }

    @objc private func onSystemWake() {
        log.info("System resumed from sleep; scheduling check")
        checkQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.triggerCheckAsync(forceBypass: false, manualTrigger: false)
        }
    }

    @objc private func onSecondInstanceWake() {
        showNotification(
            key: "already_running",
            title: "OBIT Wi-Fi Auto-Auth",
            text: "Программа уже запущена.",
            force: true
        )
        triggerCheckAsync(forceBypass: true, manualTrigger: false)
    }

    @objc private func onOpenPortalClick() {
        openPortalUrl(lastPortalUrl)
    }

    private func openPortalUrl(_ urlStr: String) {
        guard !urlStr.isEmpty,
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func onCheckNowClick() {
        triggerCheckAsync(forceBypass: true, manualTrigger: true)
    }

    private func isAutostartEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentUrl.path)
    }

    private func setAutostart(enable: Bool) {
        let fm = FileManager.default
        if !enable {
            try? fm.removeItem(at: launchAgentUrl)
            return
        }

        let execPath = Bundle.main.executablePath ?? "/Applications/OBIT Auto-Auth.app/Contents/MacOS/ObitAutoAuth"
        let plist: [String: Any] = [
            "Label": AppDelegate.bundleId,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        do {
            try fm.createDirectory(at: launchAgentUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentUrl, options: .atomic)
        } catch {
            log.warn("Autostart update failed: \(error.localizedDescription)")
        }
    }

    @objc private func onToggleAutostart() {
        let next = autostartMenuItem.state != .on
        setAutostart(enable: next)
        autostartMenuItem.state = isAutostartEnabled() ? .on : .off
    }

    @objc private func onToggleNotify() {
        let next = notifyMenuItem.state != .on
        settings.notificationsEnabled = next
        notifyMenuItem.state = next ? .on : .off
    }

    @objc private func onOpenLog() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: log.logPath) {
            log.info("Log opened")
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: log.logPath))
    }

    @objc private func onExit() {
        NSApplication.shared.terminate(nil)
    }
}
