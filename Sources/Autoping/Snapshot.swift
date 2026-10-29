import AppKit
import SwiftUI

/// Diagnostics: `Autoping -SnapshotDirectory <folder>` renders the menu bar item, the
/// popover and the settings window to PNG files (light and dark) after a few seconds of
/// pinging – handy to check the UI without screen-recording permission.
extension AppDelegate {
    func scheduleSnapshotIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "SnapshotDirectory") else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let delay = UserDefaults.standard.double(forKey: "SnapshotDelay")
        Task {
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 12))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let button = statusItem?.button {
                // The real status bar button can't be captured offscreen; render a copy.
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let copy = NSButton(title: "", target: nil, action: nil)
                    copy.isBordered = false
                    copy.image = button.image
                    copy.imagePosition = button.imagePosition
                    copy.attributedTitle = button.attributedTitle
                    copy.sizeToFit()
                    let bar = NSHostingView(rootView: Color(nsColor: .windowBackgroundColor).frame(width: copy.frame.width + 16, height: 24))
                    bar.frame.size = NSSize(width: copy.frame.width + 16, height: 24)
                    copy.frame.origin = NSPoint(x: 8, y: (24 - copy.frame.height) / 2)
                    bar.addSubview(copy)
                    Self.renderView(bar, appearance: appearance, to: folder.appendingPathComponent("menubar-\(name).png"))
                }
                Self.report("Menu bar: \(button.attributedTitle.string) | tooltip: \(button.toolTip ?? "")")
            }
            let settings = SettingsModel(preferences: preferences, monitor: monitor, notifier: notifier)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let popover = PopoverView(
                    monitor: monitor, preferences: preferences, state: PopoverState(),
                    actions: .init(openSettings: {}, showAbout: {}, quit: {})
                )
                .background(Color(nsColor: .windowBackgroundColor))
                Self.render(popover, appearance: appearance, to: folder.appendingPathComponent("popover-\(name).png"))
                Self.render(SettingsView(model: settings), appearance: appearance, to: folder.appendingPathComponent("settings-\(name).png"))
            }
            openSettings()
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController is NSHostingController<SettingsView> }),
               let screen = window.screen {
                let frame = window.frame
                let visible = screen.visibleFrame
                Self.report("Settings window \(Int(frame.width))×\(Int(frame.height)), gap left \(Int(frame.minX - visible.minX)) right \(Int(visible.maxX - frame.maxX)) top \(Int(visible.maxY - frame.maxY)) bottom \(Int(frame.minY - visible.minY))")
                window.close()
            }
            Self.report("Snapshots written to \(folder.path)")
        }
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        renderView(hosting, appearance: appearance, to: url)
    }

    private static func renderView(_ view: NSView, appearance: NSAppearance.Name, to url: URL) {
        view.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        view.display()
        writePNG(of: view, to: url)
        window.orderOut(nil)
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func writePNG(of view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
