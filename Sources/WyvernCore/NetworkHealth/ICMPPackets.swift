// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// ICMP echo and the error quotes traceroute reads back.
/// Checksums are computed in Swift so the packet does not depend on a helper library.
enum ICMPPackets {
    static let echoHeaderLength = 8
    static let ipv4EchoRequest: UInt8 = 8
    static let ipv4EchoReply: UInt8 = 0
    static let ipv6EchoRequest: UInt8 = 128
    static let ipv6EchoReply: UInt8 = 129
    static let ipv4TimeExceeded: UInt8 = 11
    static let ipv4DestinationUnreachable: UInt8 = 3
    static let ipv4PortUnreachable: UInt8 = 3
    static let ipv6TimeExceeded: UInt8 = 3
    static let ipv6DestinationUnreachable: UInt8 = 1
    static let ipv6PortUnreachable: UInt8 = 4

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += Int(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(truncatingIfNeeded: ~sum)
    }

    static func echo(
        family: IPFamily,
        identifier: UInt16,
        sequence: UInt16,
        payload: [UInt8] = []
    ) -> [UInt8] {
        let type = family == .v6 ? ipv6EchoRequest : ipv4EchoRequest
        var packet = [UInt8](repeating: 0, count: echoHeaderLength + payload.count)
        packet[0] = type
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        if !payload.isEmpty {
            packet.replaceSubrange(echoHeaderLength..., with: payload)
        }
        // IPv6 checksum covers a pseudo-header the kernel fills in for this socket type.
        if family == .v4 {
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
        }
        return packet
    }

    /// True when `data` is an echo reply for this identifier and sequence.
    /// A leading IPv4 or IPv6 header is skipped. Other replies are ignored so a
    /// shared unprivileged socket cannot record someone else's round trip.
    static func matchesEchoReply(
        _ data: [UInt8],
        family: IPFamily,
        identifier: UInt16,
        sequence: UInt16
    ) -> Bool {
        guard let header = icmpOffset(in: data) else { return false }
        let start = header
        guard data.count >= start + echoHeaderLength else { return false }
        let expected: UInt8 = family == .v6 ? ipv6EchoReply : ipv4EchoReply
        guard data[start] == expected, data[start + 1] == 0 else { return false }
        let seenID = UInt16(data[start + 4]) << 8 | UInt16(data[start + 5])
        let seenSequence = UInt16(data[start + 6]) << 8 | UInt16(data[start + 7])
        return seenID == identifier && seenSequence == sequence
    }

    struct ErrorQuote: Equatable {
        enum Kind: Equatable {
            case timeExceeded
            case portUnreachable
            case other
        }

        var kind: Kind
        var destinationPort: UInt16?
    }

    /// Reads a time-exceeded or port-unreachable message and the UDP port it quotes.
    static func errorQuote(_ data: [UInt8], family: IPFamily) -> ErrorQuote? {
        guard let start = icmpOffset(in: data) else { return nil }
        guard data.count >= start + echoHeaderLength else { return nil }
        let type = data[start]
        let code = data[start + 1]
        let kind: ErrorQuote.Kind
        if family == .v6 {
            if type == ipv6TimeExceeded {
                kind = .timeExceeded
            } else if type == ipv6DestinationUnreachable && code == ipv6PortUnreachable {
                kind = .portUnreachable
            } else {
                kind = .other
            }
        } else if type == ipv4TimeExceeded {
            kind = .timeExceeded
        } else if type == ipv4DestinationUnreachable && code == ipv4PortUnreachable {
            kind = .portUnreachable
        } else {
            kind = .other
        }
        let port = quotedDestinationPort(data, icmpStart: start, family: family)
        return ErrorQuote(kind: kind, destinationPort: port)
    }

    private static func icmpOffset(in data: [UInt8]) -> Int? {
        guard let first = data.first else { return nil }
        if first & 0xF0 == 0x40 {
            let words = Int(first & 0x0F)
            let offset = words * 4
            guard words >= 5, data.count > offset else { return nil }
            return offset
        }
        if first & 0xF0 == 0x60 {
            let offset = 40
            guard data.count > offset else { return nil }
            return offset
        }
        return 0
    }

    /// IPv4 quotes an IP header plus the first eight bytes of UDP.
    /// IPv6 quotes the IPv6 header the same way.
    private static func quotedDestinationPort(_ data: [UInt8], icmpStart: Int, family: IPFamily) -> UInt16? {
        let quoted = icmpStart + 8
        guard data.count > quoted else { return nil }
        let headerLength: Int
        if family == .v6 {
            guard data[quoted] & 0xF0 == 0x60 else { return nil }
            headerLength = 40
        } else {
            guard data[quoted] & 0xF0 == 0x40 else { return nil }
            headerLength = Int(data[quoted] & 0x0F) * 4
            guard headerLength >= 20 else { return nil }
        }
        let udp = quoted + headerLength
        guard data.count >= udp + 4 else { return nil }
        return UInt16(data[udp + 2]) << 8 | UInt16(data[udp + 3])
    }
}
