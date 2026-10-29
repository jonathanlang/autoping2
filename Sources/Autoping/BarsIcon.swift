import AppKit

/// The menu bar signal icon: five rising bars, the inactive ones faded.
/// Drawn as a template image so it adapts to light, dark and tinted menu bars.
@MainActor
enum BarsIcon {
    static let count = 5

    private static let images = (0...count).map { makeImage(active: $0) }

    /// `active` in 0…5.
    static func image(active: Int) -> NSImage {
        images[min(max(active, 0), count)]
    }

    private static func makeImage(active: Int) -> NSImage {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 1.5
        let size = NSSize(width: CGFloat(count) * barWidth + CGFloat(count - 1) * gap, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            for index in 0..<count {
                let height = 4 + CGFloat(index) * 2.5
                let rect = NSRect(x: CGFloat(index) * (barWidth + gap), y: 1, width: barWidth, height: height)
                NSColor.black.withAlphaComponent(index < active ? 1 : 0.25).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "\(active) of 5 bars")
        return image
    }

    static let offline: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: String(localized: "Offline"))!
            .withSymbolConfiguration(configuration)!
        image.isTemplate = true
        return image
    }()
}
