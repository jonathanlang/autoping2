import Foundation
import Testing
@testable import AutopingCore

struct ConnectionScorerTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let timeout: TimeInterval = 4
    let threshold: TimeInterval = 0.1

    func ping(_ sequence: UInt16, age: TimeInterval, rtt: TimeInterval? = nil, lost: Bool = false) -> PingRecord {
        let sent = now.addingTimeInterval(-age)
        return PingRecord(sequence: sequence, sent: sent, reply: rtt.map { sent.addingTimeInterval($0) }, lost: lost)
    }

    func evaluate(_ pings: [PingRecord]) -> ConnectionScorer.Evaluation {
        ConnectionScorer.evaluate(pings: pings, now: now, timeout: timeout, slowThreshold: threshold)
    }

    @Test func fastRepliesGiveFullBars() {
        let result = evaluate((0..<10).map { ping(UInt16($0), age: Double(10 - $0), rtt: 0.02) })
        #expect(result.level == 1)
        #expect(result.lossPercent == 0)
        #expect(ConnectionScorer.bars(for: result.level!) == 5)
    }

    @Test func slowReplyFallsLinearlyOverNineHundredMilliseconds() {
        // 100 ms threshold + 450 ms = halfway to 0
        let result = evaluate([ping(1, age: 2, rtt: 0.55)])
        #expect(abs(result.level! - 0.5) < 1e-9)
        #expect(ConnectionScorer.bars(for: result.level!) == 3)
    }

    @Test func pendingYoungPingIsNotScored() {
        let result = evaluate([ping(1, age: 0.5)])
        #expect(result.level == nil)
        #expect(result.newlyLost.isEmpty)
    }

    @Test func unansweredPingBetweenSlowLimitAndTimeoutCountsAsSlow() {
        // 2 s without reply: rtt treated as 2 s, past the slow range but not lost yet
        let result = evaluate([ping(1, age: 2)])
        #expect(abs(result.level! - (1 - 1.9 / 0.9)) < 1e-9)
        #expect(result.newlyLost.isEmpty)
        #expect(result.lossPercent == 0)
    }

    @Test func timedOutPingIsLostOnce() {
        let first = evaluate([ping(1, age: 5)])
        #expect(first.newlyLost == [1])
        #expect(first.lossPercent == 100)

        let second = evaluate([ping(1, age: 6, lost: true)])
        #expect(second.newlyLost.isEmpty)
        #expect(second.lossPercent == 100)
    }

    @Test func oldPingsExpire() {
        let result = evaluate([ping(1, age: 31, rtt: 0.01), ping(2, age: 1, rtt: 0.01)])
        #expect(result.expired == [1])
        #expect(result.level == 1)
    }

    @Test func recentPingsWeighMore() {
        // old lost ping, then a good one: the good one has weight 1.2
        let result = evaluate([ping(1, age: 10, lost: true), ping(2, age: 1, rtt: 0.01)])
        let expected = (-2.5 * 1 + 1 * 1.2) / 2.2
        #expect(abs(result.level! - expected) < 1e-9)
    }

    @Test func lossPercentCountsAllPingsInWindow() {
        // 1 lost of 4 remaining (including the young unscored one)
        let result = evaluate([
            ping(1, age: 8),
            ping(2, age: 3, rtt: 0.02),
            ping(3, age: 2, rtt: 0.02),
            ping(4, age: 0.2),
        ])
        #expect(result.lossPercent == 25)
    }

    @Test(arguments: [
        (-3.0, 1), (0.0, 1), (0.19, 1), (0.2, 2), (0.45, 3), (0.6, 4), (0.79, 4), (0.8, 5), (1.0, 5), (2.0, 5),
    ])
    func barsMatchOriginalMapping(level: Double, bars: Int) {
        #expect(ConnectionScorer.bars(for: level) == bars)
    }
}

struct StatCounterTests {
    @Test func tracksRunningAverageAndExtremes() {
        var stats = StatCounter()
        stats.addPingSent(); stats.addPingResponse(20)
        stats.addPingSent(); stats.addPingResponse(40)
        stats.addPingSent(); stats.addPingTimeout()
        stats.addPingSent(); stats.addPingResponse(30)
        #expect(stats.averageTime == 30)
        #expect(stats.fastest == 20)
        #expect(stats.slowest == 40)
        #expect(stats.lossPercent == 25)
    }
}

struct ICMPPacketTests {
    @Test func requestCarriesIdentifierSequenceAndValidChecksum() {
        let packet = ICMPPacket.echoRequest(family: .v4, identifier: 0xBEEF, sequence: 0x0102)
        #expect(packet[0] == 8)
        #expect(packet[4] == 0xBE && packet[5] == 0xEF)
        #expect(packet[6] == 0x01 && packet[7] == 0x02)
        #expect(ICMPPacket.checksum(packet) == 0)
    }

    @Test func parsesIPv4ReplyBehindIPHeader() {
        var reply = ICMPPacket.echoRequest(family: .v4, identifier: 7, sequence: 42)
        reply[0] = 0 // echo reply
        reply[2] = 0; reply[3] = 0
        let sum = ICMPPacket.checksum(reply)
        reply[2] = UInt8(sum >> 8); reply[3] = UInt8(sum & 0xFF)
        var ipHeader = [UInt8](repeating: 0, count: 20)
        ipHeader[0] = 0x45
        ipHeader[9] = 1
        #expect(ICMPPacket.parseEchoReply(ipHeader + reply, family: .v4) == .init(identifier: 7, sequence: 42))
        #expect(ICMPPacket.parseEchoReply(reply, family: .v4) == .init(identifier: 7, sequence: 42))
    }

    @Test func parsesIPv6Reply() {
        var reply = ICMPPacket.echoRequest(family: .v6, identifier: 9, sequence: 3)
        reply[0] = 129
        #expect(ICMPPacket.parseEchoReply(reply, family: .v6) == .init(identifier: 9, sequence: 3))
    }

    @Test func ignoresForeignAndCorruptPackets() {
        var foreign = ICMPPacket.echoRequest(family: .v6, identifier: 9, sequence: 3)
        foreign[0] = 129
        foreign[8] = UInt8(ascii: "X")
        #expect(ICMPPacket.parseEchoReply(foreign, family: .v6) == nil)

        let request = ICMPPacket.echoRequest(family: .v4, identifier: 1, sequence: 1)
        #expect(ICMPPacket.parseEchoReply(request, family: .v4) == nil) // type 8, not a reply

        var corrupt = request
        corrupt[0] = 0
        #expect(ICMPPacket.parseEchoReply(corrupt, family: .v4) == nil) // checksum no longer matches
    }
}
