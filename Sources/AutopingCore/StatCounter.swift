import Foundation

/// Ping statistics for one host, as shown in the statistics view.
/// Times are in milliseconds.
public struct StatCounter: Codable, Equatable, Sendable {
    public var sent = 0
    public var replied = 0
    public var lost = 0
    public var averageTime = 0.0
    public var fastest = 0.0
    public var slowest = 0.0

    public init() {}

    public var lossPercent: Double {
        sent > 0 ? Double(lost) / Double(sent) * 100 : 0
    }

    public mutating func addPingSent() {
        sent += 1
    }

    public mutating func addPingTimeout() {
        lost += 1
    }

    public mutating func addPingResponse(_ milliseconds: Double) {
        replied += 1
        if milliseconds > slowest { slowest = milliseconds }
        if fastest == 0 || milliseconds < fastest { fastest = milliseconds }
        averageTime = (averageTime * Double(replied - 1) + milliseconds) / Double(replied)
    }
}
