import AppKit
import Foundation

let bundleId = Bundle.main.bundleIdentifier ?? AppDelegate.bundleId
let currentPid = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0.processIdentifier != currentPid }

if !others.isEmpty {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.wakeNotificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
