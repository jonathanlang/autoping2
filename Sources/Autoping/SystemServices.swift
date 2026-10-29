import AppKit
import ServiceManagement
import UserNotifications

enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Autoping"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Launch at login through `SMAppService` – replaces the separate launch helper app of autoping 1.x.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// "Connection down / restored" alerts through the User Notifications framework.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks for permission if needed; false if the user denied it.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func connectionChanged(up: Bool, host: String) {
        let content = UNMutableNotificationContent()
        if up {
            content.title = String(localized: "Connection Restored")
            content.body = String(localized: "Your internet connection has been restored.")
        } else {
            content.title = String(localized: "Connection Down")
            content.body = String(localized: "Your internet connection seems to be down.")
        }
        content.subtitle = host
        content.sound = .default
        // Same identifier: a "restored" alert replaces the "down" one in Notification Center.
        center.add(UNNotificationRequest(identifier: "connection-state", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
