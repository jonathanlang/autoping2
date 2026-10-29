import AutopingCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Autoping", category: "monitor")

/// Pings the configured host once per second and turns the replies into the
/// connection state shown in the menu bar.
@MainActor @Observable
final class ConnectionMonitor {
    struct Sample: Identifiable {
        let id: Int
        let date: Date
        /// Round-trip time in ms, nil for a lost ping.
        let milliseconds: Double?
    }

    static let pingInterval: TimeInterval = 1
    static let historyLength: TimeInterval = 5 * 60
    /// After a wake from sleep the network often needs a moment; don't report an outage meanwhile.
    static let wakeGracePeriod: TimeInterval = 20

    /// No reply for a while (or no ping could be scored): the original's "fail state".
    private(set) var failed = false
    /// Just (re)started, no verdict yet.
    private(set) var connecting = true
    private(set) var paused = false
    /// Weighted connection score; see `ConnectionScorer`.
    private(set) var level = 0.0
    private(set) var latestPingTime: Double?
    private(set) var recentLossPercent = 0.0
    private(set) var host: String
    private(set) var address: ResolvedAddress?
    private(set) var problem: String?
    private(set) var history: [Sample] = []
    private(set) var sessionStats = StatCounter()
    private(set) var allTimeStats: StatCounter

    var bars: Int { ConnectionScorer.bars(for: level) }

    /// Called with `true` when the connection comes back, `false` when it goes down.
    @ObservationIgnored var onConnectionChange: ((Bool) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let store: StatsStore
    @ObservationIgnored private var pinger: ICMPPinger?
    @ObservationIgnored private var pending: [PingRecord] = []
    @ObservationIgnored private var nextSequence = UInt16.random(in: .min ... .max)
    @ObservationIgnored private var lastResponse = Date()
    @ObservationIgnored private var graceUntil = Date()
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var housekeepingCycle = 0
    @ObservationIgnored private var nextSampleID = 0

    init(preferences: Preferences, store: StatsStore) {
        self.preferences = preferences
        self.store = store
        host = preferences.hostname
        allTimeStats = store[preferences.hostname]
    }

    private var timeout: TimeInterval { TimeInterval(preferences.pingTimeout) }

    // MARK: - Lifecycle

    func start() {
        housekeepingTask?.cancel()
        housekeepingTask = repeating(every: 1) { $0.housekeep() }
        restart(grace: timeout)
    }

    /// Re-resolves the host and starts a fresh ping series, e.g. after a network change.
    func restart(grace: TimeInterval? = nil) {
        pingTask?.cancel()
        pingTask = nil
        pinger?.stop()
        pending.removeAll()
        address = nil
        connecting = true
        lastResponse = Date()
        graceUntil = Date().addingTimeInterval(grace ?? timeout)
        log.info("Starting pings to \(self.host, privacy: .public)")

        let pinger = ICMPPinger(host: host, preference: preferences.addressPreference) { [weak self] event in
            self?.handle(event)
        }
        self.pinger = pinger
        pinger.start()
    }

    /// Applies a changed host or address preference.
    func applySettings() {
        if preferences.hostname != host {
            store[host] = allTimeStats
            store.save()
            host = preferences.hostname
            allTimeStats = store[host]
            sessionStats = StatCounter()
            history.removeAll()
            latestPingTime = nil
        }
        restart()
    }

    func pause() {
        guard !paused else { return }
        paused = true
        pingTask?.cancel()
        pinger?.stop()
        pending.removeAll()
        saveStats()
    }

    func resume() {
        guard paused else { return }
        paused = false
        restart(grace: Self.wakeGracePeriod)
    }

    /// The system reports no usable network path at all.
    func networkUnavailable() {
        guard !paused else { return }
        problem = String(localized: "No network connection")
        setFailed(true)
    }

    func resetSessionStats() {
        sessionStats = StatCounter()
    }

    func resetAllTimeStats() {
        allTimeStats = StatCounter()
        saveStats()
    }

    func saveStats() {
        store[host] = allTimeStats
        store.save()
    }

    // MARK: - Pinging

    private func handle(_ event: ICMPPinger.Event) {
        switch event {
        case let .started(address):
            log.info("Pinging \(address.text, privacy: .public)")
            self.address = address
            problem = nil
            if pingTask == nil {
                pingTask = repeating(every: Self.pingInterval) { $0.sendPing() }
            }
        case let .failed(error):
            log.error("\(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
            setFailed(true)
        case let .sendFailed(reason):
            log.error("Sending to \(self.host, privacy: .public) failed: \(reason, privacy: .public)")
            problem = String(localized: "Cannot reach \(host): \(reason)")
        case let .reply(sequence, received):
            handleReply(sequence: sequence, received: received)
        }
    }

    private func sendPing() {
        guard let pinger, pinger.isReady else { return }
        let sequence = nextSequence
        nextSequence &+= 1
        pending.append(PingRecord(sequence: sequence, sent: Date()))
        pinger.send(sequence: sequence)
        if !failed {
            sessionStats.addPingSent()
            allTimeStats.addPingSent()
        }
    }

    private func handleReply(sequence: UInt16, received: Date) {
        guard let index = pending.firstIndex(where: { $0.sequence == sequence }),
              pending[index].reply == nil else { return }
        pending[index].reply = received
        let ping = pending[index]
        let milliseconds = received.timeIntervalSince(ping.sent) * 1000

        lastResponse = received
        problem = nil
        connecting = false
        setFailed(false)
        latestPingTime = milliseconds
        if milliseconds < timeout * 1000 {
            sessionStats.addPingResponse(milliseconds)
            allTimeStats.addPingResponse(milliseconds)
        }
        if !ping.lost {
            addSample(date: ping.sent, milliseconds: milliseconds)
        }
        evaluate(now: received)
    }

    // MARK: - Housekeeping (once per second, like the original)

    private func housekeep() {
        guard !paused else { return }
        let now = Date()
        let inGrace = now < graceUntil

        // Watchdog: nothing came back for a while – report the outage and start over,
        // which also re-resolves the host name.
        if !inGrace, now.timeIntervalSince(lastResponse) > timeout + 4 * Self.pingInterval {
            log.info("No reply for \(Int(now.timeIntervalSince(self.lastResponse))) s, restarting")
            setFailed(true)
            restart()
            return
        }

        evaluate(now: now)
        if connecting, !inGrace {
            connecting = false
        }

        housekeepingCycle += 1
        if housekeepingCycle >= 20 {
            housekeepingCycle = 0
            saveStats()
        }
    }

    private func evaluate(now: Date) {
        let result = ConnectionScorer.evaluate(
            pings: pending,
            now: now,
            timeout: timeout,
            slowThreshold: TimeInterval(preferences.slowPingThreshold) / 1000
        )

        for sequence in result.newlyLost {
            guard let index = pending.firstIndex(where: { $0.sequence == sequence }) else { continue }
            pending[index].lost = true
            if !failed {
                sessionStats.addPingTimeout()
                allTimeStats.addPingTimeout()
            }
            addSample(date: pending[index].sent, milliseconds: nil)
        }
        if !result.expired.isEmpty {
            pending.removeAll { result.expired.contains($0.sequence) }
        }

        recentLossPercent = result.lossPercent
        if let level = result.level {
            self.level = level
        } else if !connecting {
            setFailed(true)
        }
        history.removeAll { now.timeIntervalSince($0.date) > Self.historyLength }
    }

    private func setFailed(_ value: Bool) {
        guard value != failed else { return }
        failed = value
        log.notice("Connection \(value ? "down" : "up", privacy: .public)")
        onConnectionChange?(!value)
    }

    private func addSample(date: Date, milliseconds: Double?) {
        nextSampleID += 1
        history.append(Sample(id: nextSampleID, date: date, milliseconds: milliseconds))
    }

    /// Runs `action` at a fixed rate on the main actor until the task is cancelled.
    private func repeating(every interval: TimeInterval, _ action: @escaping (ConnectionMonitor) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                action(self)
                deadline += .seconds(interval)
                if deadline < clock.now { deadline = clock.now } // don't catch up after sleep
                try? await clock.sleep(until: deadline)
            }
        }
    }
}
