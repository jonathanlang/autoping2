import AppKit
import Network
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let notifier = Notifier()
    private(set) lazy var monitor = ConnectionMonitor(preferences: preferences, store: StatsStore())
    private(set) var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var networkRestart: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onConnectionChange = { [weak self] up in
            guard let self, preferences.showNotifications else { return }
            notifier.connectionChanged(up: up, host: monitor.host)
        }
        statusItem = StatusItemController(
            monitor: monitor,
            preferences: preferences,
            actions: .init(
                openSettings: { [weak self] in self?.openSettings() },
                showAbout: { [weak self] in self?.showAbout() },
                quit: { NSApp.terminate(nil) }
            )
        )
        monitor.start()
        observeSleep()
        observeNetwork()
        scheduleSnapshotIfRequested()

        if !preferences.askedAboutLaunchAtLogin {
            Task { await askAboutLaunchAtLogin() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.saveStats()
    }

    // MARK: - Windows

    func openSettings() {
        if let settingsModel {
            settingsModel.reload()
        } else {
            let model = SettingsModel(preferences: preferences, monitor: monitor, notifier: notifier)
            let content = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: content)
            window.title = String(localized: "\(AppInfo.name) Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Size the window to the SwiftUI content first; centering an unsized window
            // leaves it near the top once SwiftUI grows it.
            window.setContentSize(content.view.fittingSize)
            centerOnActiveScreen(window)
            settingsWindow = window
            settingsModel = model
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Centers exactly (`NSWindow.center()` sits higher) on the screen with the mouse,
    /// i.e. the one whose menu bar was just clicked.
    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        ))
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: String(localized: "A modern rebuild of autoping 1.02 by Memset Ltd. (Richard West, original concept by Kate Craig-Wood)."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func askAboutLaunchAtLogin() async {
        try? await Task.sleep(for: .seconds(2))
        preferences.askedAboutLaunchAtLogin = true
        guard !LoginItem.isEnabled else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Start \(AppInfo.name) automatically at login?")
        alert.informativeText = String(localized: "You can change this at any time in the settings.")
        alert.addButton(withTitle: String(localized: "Start at Login"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            try? LoginItem.setEnabled(true)
        }
    }

    // MARK: - System events

    /// No pings while the Mac sleeps; a grace period after waking avoids false "down" alerts.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.pause() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.resume() }
        }
    }

    /// Restarts pinging (with a fresh DNS lookup) when the network changes, and reports
    /// an outage right away when there is no network at all.
    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = "\(available)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            MainActor.assumeIsolated { self?.networkChanged(available: available, signature: signature) }
        }
        pathMonitor.start(queue: .main)
    }

    private func networkChanged(available: Bool, signature: String) {
        defer { lastPathSignature = signature }
        guard let lastPathSignature, lastPathSignature != signature else { return }

        networkRestart?.cancel()
        if !available {
            monitor.networkUnavailable()
            return
        }
        networkRestart = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !monitor.paused else { return }
            monitor.restart(grace: 10)
        }
    }
}
