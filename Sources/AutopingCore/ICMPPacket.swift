import Foundation

/// Builds and parses ICMP / ICMPv6 echo packets.
///
/// macOS allows unprivileged ICMP through `SOCK_DGRAM` sockets. For IPv4 the kernel
/// hands us the IP header in front of the ICMP message on receive; for IPv6 it does
/// not. The kernel fills in the ICMPv6 checksum itself, the IPv4 one is ours.
public enum ICMPPacket {
    public enum Family: Sendable {
        case v4, v6

        var echoRequestType: UInt8 { self == .v4 ? 8 : 128 }
        var echoReplyType: UInt8 { self == .v4 ? 0 : 129 }
    }

    public struct EchoReply: Equatable, Sendable {
        public let identifier: UInt16
        public let sequence: UInt16
    }

    /// Marks our own packets so stray echo replies of other processes are ignored.
    static let magic: [UInt8] = Array("AUTOPING".utf8)
    static let payloadLength = 56

    public static func echoRequest(family: Family, identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 8 + payloadLength)
        packet[0] = family.echoRequestType
        packet[1] = 0
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        packet.replaceSubrange(8..<(8 + magic.count), with: magic)
        for index in (8 + magic.count)..<packet.count {
            packet[index] = UInt8(truncatingIfNeeded: index)
        }
        if family == .v4 {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
        }
        return packet
    }

    /// Returns the echo reply contained in `data`, or nil for anything that is not
    /// one of our echo replies (other ICMP types, foreign payloads, truncated data).
    public static func parseEchoReply(_ data: [UInt8], family: Family) -> EchoReply? {
        var offset = 0
        if family == .v4, let first = data.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0F) * 4
            guard headerLength >= 20, data.count >= headerLength, data[9] == 1 /* ICMP */ else { return nil }
            offset = headerLength
        }
        guard data.count >= offset + 8 + magic.count else { return nil }
        guard data[offset] == family.echoReplyType, data[offset + 1] == 0 else { return nil }
        guard Array(data[(offset + 8)..<(offset + 8 + magic.count)]) == magic else { return nil }
        if family == .v4, checksum(Array(data[offset...])) != 0 { return nil }

        let identifier = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
        let sequence = UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
        return EchoReply(identifier: identifier, sequence: sequence)
    }

    /// RFC 1071 internet checksum. Over a packet that already contains its checksum the result is 0.
    public static func checksum<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var sum: UInt32 = 0
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            let low = iterator.next() ?? 0
            sum += UInt32(high) << 8 | UInt32(low)
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}
