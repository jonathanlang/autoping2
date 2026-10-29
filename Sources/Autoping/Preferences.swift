import Foundation
import Observation

enum DisplayMode: Int, CaseIterable, Identifiable {
    case iconAndText = 0
    case iconOnly = 1
    case textOnly = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .iconAndText: String(localized: "Icon and Text")
        case .iconOnly: String(localized: "Icon Only")
        case .textOnly: String(localized: "Text Only")
        }
    }

    var showsIcon: Bool { self != .textOnly }
    var showsText: Bool { self != .iconOnly }
}

enum AddressPreference: Int, CaseIterable, Identifiable {
    case automatic = 0
    case ipv4 = 1
    case ipv6 = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        }
    }
}

/// User settings, stored in UserDefaults under the key names of the original app.
@MainActor @Observable
final class Preferences {
    private enum Key {
        static let hostname = "Hostname"
        static let pingTimeout = "PingTimeout"
        static let slowPingThreshold = "SlowPingLowThreshold"
        static let showPacketLossText = "ShowPacketLossText"
        static let showNotifications = "ShowNotifications"
        static let displayMode = "DisplayMode"
        static let addressPreference = "AddressPreference"
        static let askedAboutLaunchAtLogin = "AskedAboutLaunchAtLogin"
    }

    static let defaultHostname = "1.1.1.1"
    static let defaultPingTimeout = 4
    static let defaultSlowPingThreshold = 100
    static let slowPingThresholdRange = 50...2000
    static let pingTimeoutRange = 1...10

    @ObservationIgnored private let defaults: UserDefaults

    var hostname: String { didSet { defaults.set(hostname, forKey: Key.hostname) } }
    /// Seconds after which an unanswered ping counts as lost.
    var pingTimeout: Int { didSet { defaults.set(pingTimeout, forKey: Key.pingTimeout) } }
    /// Milliseconds up to which a reply counts as perfectly fast.
    var slowPingThreshold: Int { didSet { defaults.set(slowPingThreshold, forKey: Key.slowPingThreshold) } }
    var showPacketLossText: Bool { didSet { defaults.set(showPacketLossText, forKey: Key.showPacketLossText) } }
    var showNotifications: Bool { didSet { defaults.set(showNotifications, forKey: Key.showNotifications) } }
    var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) } }
    var addressPreference: AddressPreference { didSet { defaults.set(addressPreference.rawValue, forKey: Key.addressPreference) } }
    var askedAboutLaunchAtLogin: Bool { didSet { defaults.set(askedAboutLaunchAtLogin, forKey: Key.askedAboutLaunchAtLogin) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hostname: Self.defaultHostname,
            Key.pingTimeout: Self.defaultPingTimeout,
            Key.slowPingThreshold: Self.defaultSlowPingThreshold,
            Key.showPacketLossText: false,
            Key.showNotifications: false,
            Key.displayMode: DisplayMode.iconAndText.rawValue,
            Key.addressPreference: AddressPreference.automatic.rawValue,
            Key.askedAboutLaunchAtLogin: false,
        ])
        hostname = defaults.string(forKey: Key.hostname) ?? Self.defaultHostname
        pingTimeout = defaults.integer(forKey: Key.pingTimeout)
        slowPingThreshold = defaults.integer(forKey: Key.slowPingThreshold)
        showPacketLossText = defaults.bool(forKey: Key.showPacketLossText)
        showNotifications = defaults.bool(forKey: Key.showNotifications)
        displayMode = DisplayMode(rawValue: defaults.integer(forKey: Key.displayMode)) ?? .iconAndText
        addressPreference = AddressPreference(rawValue: defaults.integer(forKey: Key.addressPreference)) ?? .automatic
        askedAboutLaunchAtLogin = defaults.bool(forKey: Key.askedAboutLaunchAtLogin)
    }

    func restoreDefaults() {
        hostname = Self.defaultHostname
        pingTimeout = Self.defaultPingTimeout
        slowPingThreshold = Self.defaultSlowPingThreshold
        showPacketLossText = false
        showNotifications = false
        displayMode = .iconAndText
        addressPreference = .automatic
    }
}
