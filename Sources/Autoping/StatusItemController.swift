import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item: signal bars and/or latency text, a tooltip, a popover
/// with details on click and a small menu on right-click.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        var openSettings: () -> Void
        var showAbout: () -> Void
        var quit: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: ConnectionMonitor
    private let preferences: Preferences
    private let actions: Actions
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    init(monitor: ConnectionMonitor, preferences: Preferences, actions: Actions) {
        self.monitor = monitor
        self.preferences = preferences
        self.actions = actions
        super.init()

        var popoverActions = actions
        popoverActions.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            actions.openSettings()
        }
        popoverActions.showAbout = { [weak self] in
            self?.popover.performClose(nil)
            actions.showAbout()
        }
        let content = NSHostingController(
            rootView: PopoverView(monitor: monitor, preferences: preferences, state: PopoverState(), actions: popoverActions)
        )
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        render()
    }

    var button: NSStatusBarButton? { statusItem.button }

    // MARK: - Rendering

    /// Re-renders whenever an observed property of the monitor or the preferences changes.
    private func render() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private func update() {
        guard let button = statusItem.button else { return }
        let mode = preferences.displayMode

        let image: NSImage
        let text: String
        if monitor.failed {
            image = BarsIcon.offline
            text = String(localized: "Offline")
        } else if monitor.connecting || monitor.paused {
            image = BarsIcon.image(active: 0)
            text = "…"
        } else {
            image = BarsIcon.image(active: monitor.bars)
            text = preferences.showPacketLossText
                ? "\(latencyText) (\(Formatting.percent(monitor.recentLossPercent)))"
                : latencyText
        }

        switch mode {
        case .iconAndText:
            button.image = BarsIcon.image(image, text: text, font: font)
            button.title = ""
        case .iconOnly:
            button.image = image
            button.title = ""
        case .textOnly:
            button.image = nil
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        }
        button.toolTip = tooltip
    }

    private var latencyText: String {
        monitor.latestPingTime.map(Formatting.milliseconds) ?? "–"
    }

    private var tooltip: String {
        var lines = [monitor.host]
        if monitor.failed {
            lines.append(monitor.problem ?? String(localized: "Connection down"))
        } else {
            lines.append(String(localized: "Latest ping time: \(latencyText)"))
            lines.append(String(localized: "Recent packet loss: \(Formatting.percent(monitor.recentLossPercent))"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Interaction

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Settings…"), key: ",", action: #selector(openSettings)))
        menu.addItem(item(String(localized: "About \(AppInfo.name)"), action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(AppInfo.name)"), key: "q", action: #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, key: String = "", action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() { actions.openSettings() }
    @objc private func showAbout() { actions.showAbout() }
    @objc private func quit() { actions.quit() }
}

enum Formatting {
    static func milliseconds(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    static func preciseMilliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    /// `value` in 0…100.
    static func percent(_ value: Double, fractionDigits: Int = 0) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(fractionDigits)))
    }
}
