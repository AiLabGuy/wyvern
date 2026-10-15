// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Classifies a URL host before the app connects to it.
///
/// Literal addresses are parsed here. Names are not resolved, so a public name that
/// later resolves to a private address is outside this check.
public enum NetworkHostPolicy {
    /// Loopback, the unspecified address, or link-local (including cloud metadata).
    /// These are never a valid update or block-list target.
    public static func isLoopbackOrLinkLocal(_ host: String) -> Bool {
        switch classify(host) {
        case .loopback, .linkLocal, .unspecified, .ambiguous:
            return true
        case .lan, .localName, .publicName, .publicAddress:
            return false
        }
    }

    /// True when the host is not a public DNS name or a public address.
    /// Includes loopback, link-local, RFC1918, CGNAT, local-only names, and multicast.
    public static func isNonPublic(_ host: String) -> Bool {
        switch classify(host) {
        case .publicName, .publicAddress:
            return false
        case .loopback, .linkLocal, .unspecified, .ambiguous, .lan, .localName:
            return true
        }
    }

    /// A name that only resolves on the local link (`*.local`, `*.internal`, and the like).
    public static func isLocalOnlyName(_ host: String) -> Bool {
        if case .localName = classify(host) { return true }
        return false
    }

    /// An address the user can name on purpose: RFC1918, CGNAT, or IPv6 ULA.
    /// Multicast, documentation ranges, and names are not included.
    public static func isUserSpecifiedLAN(_ host: String) -> Bool {
        let text = strip(host)
        if text.contains(":") {
            guard let hextets = expandIPv6(text) else { return false }
            if isIPv4Embedded(hextets) {
                return isUserLANIPv4(ipv4Octets(hextets))
            }
            return hextets[0] & 0xfe00 == 0xfc00
        }
        guard let parsed = ipv4(text), parsed.suspicious == false, parsed.octets.count == 4 else {
            return false
        }
        return isUserLANIPv4(parsed.octets)
    }

    private enum Kind {
        case loopback
        case linkLocal
        case unspecified
        case ambiguous
        case lan
        case localName
        case publicName
        case publicAddress
    }

    private static func strip(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        return host
    }

    private static func isUserLANIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1]
        if a == 10 { return true }
        if a == 192, b == 168 { return true }
        if a == 172, (16...31).contains(b) { return true }
        if a == 100, (64...127).contains(b) { return true }
        return false
    }

    /// IPv4-mapped (`::ffff:a.b.c.d`) or IPv4-compatible (`::a.b.c.d`), not `::` or `::1`.
    private static func isIPv4Embedded(_ hextets: [UInt16]) -> Bool {
        guard hextets[0] == 0, hextets[1] == 0, hextets[2] == 0,
              hextets[3] == 0, hextets[4] == 0 else {
            return false
        }
        if hextets[5] == 0xffff { return true }
        return hextets[5] == 0 && (hextets[6] != 0 || hextets[7] != 0)
    }

    private static func ipv4Octets(_ hextets: [UInt16]) -> [Int] {
        [
            Int(hextets[6] >> 8),
            Int(hextets[6] & 0xff),
            Int(hextets[7] >> 8),
            Int(hextets[7] & 0xff)
        ]
    }

    private static func classify(_ raw: String) -> Kind {
        let host = strip(raw)
        guard !host.isEmpty else { return .ambiguous }
        if host.contains(":") {
            return classifyIPv6(host)
        }
        if host.hasPrefix("0x"), host.dropFirst(2).allSatisfy(\.isHexDigit) {
            return .ambiguous
        }
        if let parsed = ipv4(host) {
            if parsed.suspicious { return .ambiguous }
            return classifyIPv4(parsed.octets)
        }
        if host.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return .ambiguous
        }
        if isLocalName(host) {
            return host == "localhost" || host == "localhost.localdomain" || host.hasSuffix(".localhost")
                ? .loopback
                : .localName
        }
        return .publicName
    }

    private static func isLocalName(_ host: String) -> Bool {
        if host == "localhost" || host == "localhost.localdomain" { return true }
        let suffixes = [".localhost", ".local", ".localdomain", ".internal", ".home.arpa", ".lan"]
        return suffixes.contains { host.hasSuffix($0) }
    }

    private struct IPv4Parse {
        var octets: [Int]
        var suspicious: Bool
    }

    /// Dotted decimal, 1 to 4 labels. Short forms, leading zeros, and out-of-range
    /// labels are suspicious: stacks disagree on `0177.0.0.1` and `127.1`.
    /// A numeric dotted token is never treated as a public DNS name.
    private static func ipv4(_ host: String) -> IPv4Parse? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        guard parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }) else {
            return nil
        }
        var octets: [Int] = []
        var suspicious = parts.count != 4
        for part in parts {
            if part.count > 1, part.first == "0" { suspicious = true }
            guard (1...3).contains(part.count), let value = Int(part), value <= 255 else {
                return IPv4Parse(octets: [], suspicious: true)
            }
            octets.append(value)
        }
        return IPv4Parse(octets: octets, suspicious: suspicious)
    }

    private static func classifyIPv4(_ octets: [Int]) -> Kind {
        guard octets.count == 4 else { return .ambiguous }
        let a = octets[0], b = octets[1]
        if a == 0 { return .unspecified }
        if a == 127 { return .loopback }
        if a == 169, b == 254 { return .linkLocal }
        if a == 10 { return .lan }
        if a == 192, b == 168 { return .lan }
        if a == 172, (16...31).contains(b) { return .lan }
        if a == 100, (64...127).contains(b) { return .lan }
        if a == 192, b == 0, octets[2] == 0 { return .lan }
        if a == 192, b == 0, octets[2] == 2 { return .lan }
        if a == 198, b == 51, octets[2] == 100 { return .lan }
        if a == 203, b == 0, octets[2] == 113 { return .lan }
        if a == 198, (18...19).contains(b) { return .lan }
        if a >= 224 { return .lan }
        return .publicAddress
    }

    private static func classifyIPv6(_ host: String) -> Kind {
        guard let hextets = expandIPv6(host) else { return .ambiguous }
        if hextets.allSatisfy({ $0 == 0 }) { return .unspecified }
        if hextets.dropLast().allSatisfy({ $0 == 0 }), hextets[7] == 1 { return .loopback }
        let first = hextets[0]
        if first & 0xffc0 == 0xfe80 { return .linkLocal }
        if first & 0xfe00 == 0xfc00 { return .lan }
        if first & 0xff00 == 0xff00 { return .lan }
        if isIPv4Embedded(hextets) {
            return classifyIPv4(ipv4Octets(hextets))
        }
        return .publicAddress
    }

    /// Eight hextets, or nil when the text is not a plain IPv6 literal.
    private static func expandIPv6(_ host: String) -> [UInt16]? {
        var text = host
        var tail: [UInt16] = []
        if text.contains(".") {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            let v4text = String(text[text.index(after: colon)...])
            guard let parsed = ipv4(v4text), parsed.octets.count == 4, !parsed.suspicious else { return nil }
            let octets = parsed.octets
            tail = [
                UInt16((octets[0] << 8) | octets[1]),
                UInt16((octets[2] << 8) | octets[3])
            ]
            text = String(text[..<colon])
            // `2001:db8::1.2.3.4` loses one colon of `::` when the v4 tail is cut off.
            if text.hasSuffix(":"), text.contains("::") == false {
                text.append(":")
            }
        }
        if text.isEmpty {
            guard tail.count == 8 else { return nil }
            return tail
        }
        if text == ":" || text == "::" {
            let zeros = Array(repeating: UInt16(0), count: 8 - tail.count)
            guard zeros.count >= 1 else { return nil }
            return zeros + tail
        }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let emptyCount = pieces.filter(\.isEmpty).count
        if emptyCount > 3 { return nil }
        if emptyCount == 0 {
            guard pieces.count + tail.count == 8, let parsed = parseHextets(pieces) else { return nil }
            return parsed + tail
        }
        guard text.contains("::"), text.components(separatedBy: "::").count == 2 else { return nil }
        let sides = text.components(separatedBy: "::")
        let left = sides[0].isEmpty ? [] : sides[0].split(separator: ":").map(String.init)
        let right = sides[1].isEmpty ? [] : sides[1].split(separator: ":").map(String.init)
        let missing = 8 - tail.count - left.count - right.count
        guard missing >= 1,
              let leftParsed = parseHextets(left),
              let rightParsed = parseHextets(right) else {
            return nil
        }
        return leftParsed + Array(repeating: UInt16(0), count: missing) + rightParsed + tail
    }

    private static func parseHextets(_ parts: [String]) -> [UInt16]? {
        var out: [UInt16] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            guard (1...4).contains(part.count), part.allSatisfy(\.isHexDigit),
                  let value = UInt16(part, radix: 16) else {
                return nil
            }
            out.append(value)
        }
        return out
    }
}
