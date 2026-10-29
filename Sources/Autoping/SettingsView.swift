import SwiftUI

/// State and actions of the settings window. (An observable object instead of
/// `@State`, whose macro needs Xcode and is missing from the Command Line Tools.)
@MainActor @Observable
final class SettingsModel {
    let preferences: Preferences
    let monitor: ConnectionMonitor
    private let notifier: Notifier

    var draftHost = ""
    var threshold = 100.0
    var launchAtLogin = false
    var loginItemMessage: String?
    var notificationsDenied = false

    init(preferences: Preferences, monitor: ConnectionMonitor, notifier: Notifier) {
        self.preferences = preferences
        self.monitor = monitor
        self.notifier = notifier
        reload()
    }

    var addressDescription: String {
        if let problem = monitor.problem { return problem }
        guard let address = monitor.address else { return String(localized: "Resolving…") }
        return address.text
    }

    func reload() {
        draftHost = preferences.hostname
        threshold = Double(preferences.slowPingThreshold)
        launchAtLogin = LoginItem.isEnabled
        updateLoginItemMessage()
    }

    func applyHost() {
        let host = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            draftHost = preferences.hostname
            return
        }
        guard host != preferences.hostname else { return }
        preferences.hostname = host
        draftHost = host
        monitor.applySettings()
    }

    /// The slider value in steps of 10 ms.
    var roundedThreshold: Int {
        Int((threshold / 10).rounded()) * 10
    }

    func applyThreshold() {
        preferences.slowPingThreshold = roundedThreshold
    }

    func notificationsToggled(_ enabled: Bool) {
        guard enabled else { return }
        Task {
            notificationsDenied = !(await notifier.requestAuthorization())
            if notificationsDenied { preferences.showNotifications = false }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled != LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(enabled)
            } catch {
                launchAtLogin = LoginItem.isEnabled
                loginItemMessage = error.localizedDescription
                return
            }
        }
        updateLoginItemMessage()
    }

    func restoreDefaults() {
        preferences.restoreDefaults()
        reload()
        monitor.applySettings()
    }

    private func updateLoginItemMessage() {
        loginItemMessage = LoginItem.needsApproval
            ? String(localized: "Allow \(AppInfo.name) in System Settings to start it at login.")
            : nil
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @FocusState private var hostFocused: Bool

    private var preferences: Preferences { model.preferences }

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Connection") {
                TextField("Host to ping", text: $model.draftHost, prompt: Text(verbatim: Preferences.defaultHostname))
                    .focused($hostFocused)
                    .onSubmit(model.applyHost)
                    .onChange(of: hostFocused) { _, focused in
                        if !focused { model.applyHost() }
                    }
                LabeledContent("Address") {
                    Text(model.addressDescription)
                        .foregroundStyle(model.monitor.problem == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                Picker("IP version", selection: $preferences.addressPreference) {
                    ForEach(AddressPreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: preferences.addressPreference) { model.monitor.applySettings() }

                VStack(alignment: .leading) {
                    LabeledContent("Slow ping threshold") {
                        Text(verbatim: "\(model.roundedThreshold) ms")
                            .monospacedDigit()
                    }
                    // No `step:` – it would draw a tick mark for every step.
                    Slider(
                        value: $model.threshold,
                        in: Double(Preferences.slowPingThresholdRange.lowerBound)...Double(Preferences.slowPingThresholdRange.upperBound)
                    ) { editing in
                        if !editing { model.applyThreshold() }
                    }
                    .labelsHidden()
                    Text("The default settings work well with most connections. Increase the slow ping threshold if you're on a connection that always has high latency (e.g. via satellite) and the indicator never reaches 5 bars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Ping timeout") {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(preferences.pingTimeout) s")
                            .monospacedDigit()
                        Stepper("Ping timeout", value: $preferences.pingTimeout, in: Preferences.pingTimeoutRange)
                            .labelsHidden()
                    }
                }
            }

            Section("Menu Bar") {
                Picker("Display", selection: $preferences.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show packet loss in menu bar", isOn: $preferences.showPacketLossText)
                    .disabled(!preferences.displayMode.showsText)
            }

            Section {
                Toggle("Connection up/down alerts", isOn: $preferences.showNotifications)
                    .onChange(of: preferences.showNotifications) { _, enabled in model.notificationsToggled(enabled) }
                if model.notificationsDenied {
                    Text("Notifications are turned off for \(AppInfo.name) in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _, enabled in model.setLaunchAtLogin(enabled) }
                if let message = model.loginItemMessage {
                    HStack {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Default Settings", action: model.restoreDefaults)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
