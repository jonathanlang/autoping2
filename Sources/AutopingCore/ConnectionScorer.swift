import Foundation

/// One echo request that is still inside the averaging window.
public struct PingRecord: Equatable, Sendable {
    public let sequence: UInt16
    public let sent: Date
    public var reply: Date?
    public var lost = false

    public init(sequence: UInt16, sent: Date, reply: Date? = nil, lost: Bool = false) {
        self.sequence = sequence
        self.sent = sent
        self.reply = reply
        self.lost = lost
    }
}

/// The connection-quality algorithm of the original autoping 1.02, reconstructed
/// from its binary (`-[AppDelegate onHousekeepingTimer:]` and `updateIconState:error:`).
///
/// Every ping of the last 30 seconds gets a score:
/// - answered within the slow threshold: 1
/// - answered slower: falls linearly to 0 over the next 900 ms, and further down to -2.5
/// - unanswered after the timeout (or answered after it): -2.5
/// - unanswered but younger than threshold + 900 ms: no score yet
///
/// The scores are averaged with weights growing by 1.2 per ping, so recent pings
/// dominate. The average (clamped to 0…1) selects 1 to 5 bars.
public enum ConnectionScorer {
    public static let averagingWindow: TimeInterval = 30
    /// The score reaches 0 this far above the slow-ping threshold.
    public static let slowRange: TimeInterval = 0.9
    public static let lostScore = -2.5
    public static let weightGrowth = 1.2
    public static let barCount = 5

    public struct Evaluation: Equatable, Sendable {
        /// Pings older than the averaging window; drop them.
        public var expired: [UInt16] = []
        /// Pings that just crossed the timeout without a valid reply.
        public var newlyLost: [UInt16] = []
        /// Weighted average of all scores, nil if no ping could be scored yet.
        public var level: Double?
        /// Share of lost pings among the pings that remain in the window, 0…100.
        public var lossPercent: Double = 0
    }

    /// `pings` must be ordered oldest first (the order they were sent in).
    public static func evaluate(
        pings: [PingRecord],
        now: Date,
        timeout: TimeInterval,
        slowThreshold: TimeInterval
    ) -> Evaluation {
        var result = Evaluation()
        var lostCount = 0
        var weightedSum = 0.0
        var weightTotal = 0.0
        var weight = 1.0
        let slowLimit = slowThreshold + slowRange

        for ping in pings {
            let age = now.timeIntervalSince(ping.sent)
            if age > averagingWindow {
                result.expired.append(ping.sequence)
                continue
            }

            let roundTrip: TimeInterval
            if let reply = ping.reply {
                roundTrip = reply.timeIntervalSince(ping.sent)
            } else if age < slowLimit {
                continue
            } else {
                roundTrip = age
            }

            let score: Double
            if roundTrip > timeout {
                lostCount += 1
                if !ping.lost { result.newlyLost.append(ping.sequence) }
                score = lostScore
            } else if roundTrip <= slowThreshold {
                score = 1
            } else {
                score = max(lostScore, 1 - (roundTrip - slowThreshold) / slowRange)
            }

            weightedSum += score * weight
            weightTotal += weight
            weight *= weightGrowth
        }

        let remaining = pings.count - result.expired.count
        result.lossPercent = remaining > 0 ? Double(lostCount) / Double(remaining) * 100 : 0
        result.level = weightTotal > 0 ? weightedSum / weightTotal : nil
        return result
    }

    /// 1…5 bars for a level from `evaluate`.
    public static func bars(for level: Double) -> Int {
        let clamped = min(max(level, 0), 1)
        return min(Int((clamped * Double(barCount)).rounded(.down)), barCount - 1) + 1
    }
}
