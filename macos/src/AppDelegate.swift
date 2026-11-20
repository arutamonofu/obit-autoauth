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
    private let statusMenuItem = NSMenuItem(title: "Проверка входа...", action: nil, keyEquivalent: "")
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
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
            self.statusBarItem.button?.image = self.renderMenuBarIcon(for: p.iconColor)
        }
    }

    private func obitMarkPath(scale: CGFloat, offset: NSPoint) -> NSBezierPath {
        // Official OBIT 'O' mark normalized to 0..14 box, mapped by scale & offset (flipped top-left coords)
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            return NSPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // Outer contour (square bottom-left corner)
        path.move(to: pt(7.55, 0.00))
        path.curve(to: pt(1.18, 6.44), controlPoint1: pt(4.01, 0.00), controlPoint2: pt(1.18, 2.89))
        path.line(to: pt(0.00, 6.44))
        path.line(to: pt(0.00, 14.00))
        path.line(to: pt(7.55, 14.00))
        path.line(to: pt(7.55, 12.82))
        path.curve(to: pt(14.00, 6.38), controlPoint1: pt(11.10, 12.82), controlPoint2: pt(14.00, 9.92))
        path.curve(to: pt(7.55, 0.00), controlPoint1: pt(14.00, 2.89), controlPoint2: pt(11.10, 0.00))
        path.close()

        // Inner cutout
        path.move(to: pt(7.55, 3.37))
        path.curve(to: pt(10.62, 6.44), controlPoint1: pt(9.27, 3.37), controlPoint2: pt(10.62, 4.73))
        path.curve(to: pt(7.55, 9.51), controlPoint1: pt(10.62, 8.15), controlPoint2: pt(9.27, 9.51))
        path.line(to: pt(7.55, 6.44))
        path.line(to: pt(4.48, 6.44))
        path.curve(to: pt(7.55, 3.37), controlPoint1: pt(4.48, 4.73), controlPoint2: pt(5.84, 3.37))
        path.close()

        return path
    }

    private func renderMenuBarIcon(for color: IconColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            let fg = NSColor.black.withAlphaComponent(color == .gray ? 0.45 : 1.0)
            fg.setFill()
            self.obitMarkPath(scale: 14.5 / 14.0, offset: NSPoint(x: 1.5, y: 1.75)).fill()

            if color == .gray {
                return true
            }

            let badgeCenter = NSPoint(x: 13.2, y: 13.2)
            let cutoutRadius: CGFloat = 5.0
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(
                x: badgeCenter.x - cutoutRadius,
                y: badgeCenter.y - cutoutRadius,
                width: cutoutRadius * 2,
                height: cutoutRadius * 2
            )).fill()
            NSGraphicsContext.restoreGraphicsState()

            switch color {
            case .green:
                NSColor.black.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.9
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: 10.4, y: 13.4))
                check.line(to: NSPoint(x: 12.2, y: 15.2))
                check.line(to: NSPoint(x: 15.8, y: 11.3))
                check.stroke()
            case .orange:
                NSColor.black.setStroke()
                let stem = NSBezierPath()
                stem.lineWidth = 1.9
                stem.lineCapStyle = .round
                stem.move(to: NSPoint(x: 13.2, y: 10.3))
                stem.line(to: NSPoint(x: 13.2, y: 13.4))
                stem.stroke()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.15, y: 14.8, width: 2.1, height: 2.1)).fill()
            case .red:
                let r: CGFloat = 4.2
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: badgeCenter.x - r,
                    y: badgeCenter.y - r,
                    width: r * 2,
                    height: r * 2
                )).fill()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                NSColor.black.setStroke()
                let stem = NSBezierPath()
                stem.lineWidth = 1.7
                stem.lineCapStyle = .round
                stem.move(to: NSPoint(x: 13.2, y: 10.7))
                stem.line(to: NSPoint(x: 13.2, y: 13.3))
                stem.stroke()
                NSBezierPath(ovalIn: NSRect(x: 12.3, y: 14.4, width: 1.8, height: 1.8)).fill()
                NSGraphicsContext.restoreGraphicsState()
            case .gray:
                break
            }
            return true
        }
        img.isTemplate = true
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
