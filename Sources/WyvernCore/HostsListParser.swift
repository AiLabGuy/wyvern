// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Hosts files and plain domain lists (one host per line, `#` comments).
///
/// OISD `domainswild` lines look like `*.example.com`. The `*.` prefix is stripped
/// because content rules already match subdomains. `domainswild2` is the same list
/// without that prefix. International names are punycode (`xn--`); anything that
/// is still non-ASCII is dropped so one line cannot fail a WebKit compile.
public enum HostsListParser {
    /// Names a hosts file uses for the machine itself. They are not remote hosts.
    public static let skippedHosts: Set<String> = [
        "localhost",
        "localhost.localdomain",
        "local",
        "broadcasthost",
        "0.0.0.0"
    ]

    /// Longer lines are skipped. A hosts name is at most 253 characters, so a longer
    /// line is padding or a single token meant to inflate the parser.
    public static let maxLineScalars = 16_384

    /// Unique names kept before parent collapse. Collapse only reduces the count, so a
    /// list of millions of children of one parent is refused instead of being truncated
    /// into that parent after the whole set has been stored.
    public static let maxUniqueBeforeCollapse = 1_200_000

    public enum ParseOutcome: Equatable {
        case domains([String])
        case tooLarge
    }

    /// Unique sorted domains. A name is omitted when a parent in the same set already covers it.
    /// A list that exceeds `maxUnique` before that collapse is returned as an empty list;
    /// `parseOutcome` reports it as too large so the download is rejected.
    public static func parse(_ text: String, maxUnique: Int = maxUniqueBeforeCollapse) -> [String] {
        switch parseOutcome(text, maxUnique: maxUnique) {
        case .domains(let domains):
            return domains
        case .tooLarge:
            return []
        }
    }

    public static func parseOutcome(_ text: String, maxUnique: Int = maxUniqueBeforeCollapse) -> ParseOutcome {
        var found = Set<String>()
        var overflow = false
        let limit = max(0, maxUnique)
        forEachLine(in: text) { line in
            if overflow { return }
            var content = line
            if let hash = content.firstIndex(of: "#") {
                content = content[..<hash]
            }
            let fields = content.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{000c}" })
            for field in fields {
                guard let domain = canonicalHost(String(field)) else { continue }
                found.insert(domain)
                if found.count > limit {
                    overflow = true
                    return
                }
            }
        }
        if overflow { return .tooLarge }
        return .domains(collapse(found))
    }

    /// `! Title:` or `# Title:` from the first matching header, else nil.
    public static func listTitle(_ text: String) -> String? {
        var found: String?
        forEachLine(in: text) { line in
            guard found == nil else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            let prefixes = ["! title:", "# title:", "!title:", "#title:"]
            guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else { return }
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let name = trimmed[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            if name.count > 120 {
                found = String(name.prefix(120))
            } else {
                found = name
            }
        }
        return found
    }

    /// Drops names that have a parent domain in `domains`. Result is sorted.
    public static func collapse(_ domains: Set<String>) -> [String] {
        let sorted = domains.sorted()
        var kept: [String] = []
        kept.reserveCapacity(sorted.count)
        for domain in sorted {
            if coveredByParent(domain, domains) { continue }
            kept.append(domain)
        }
        return kept
    }

    /// Lowercased ASCII host, or nil when it cannot be a block rule.
    /// Requires a dot, punycode-encodes each label, and rejects a numeric final label.
    public static func canonicalHost(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.hasPrefix("\u{FEFF}") {
            token.removeFirst()
        }
        if token.hasPrefix("*.") {
            token.removeFirst(2)
        }
        while token.hasSuffix(".") {
            token.removeLast()
        }
        guard !token.isEmpty else { return nil }
        guard skippedHosts.contains(token) == false else { return nil }
        guard isIPLiteral(token) == false else { return nil }
        guard token.contains(".") else { return nil }
        guard let encoded = punycodeDomain(token) else { return nil }
        guard encoded.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let labels = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last, last.isEmpty == false, last.allSatisfy(\.isNumber) == false else { return nil }
        guard isValidDomainName(encoded) else { return nil }
        return encoded
    }

    public static func isIPLiteral(_ token: String) -> Bool {
        if token.contains(":") || token.contains("%") {
            return true
        }
        if token.contains("[") || token.contains("]") {
            return true
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return false }
            guard let value = Int(part), (0...255).contains(value) else { return false }
        }
        return true
    }

    public static func isValidDomainName(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        guard domain.contains(" ") == false else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard isValidLabel(label) else { return false }
        }
        return true
    }

    /// Walks scalars so a CRLF pair is two breaks. Swift's `Character` treats `\r\n` as one grapheme.
    private static func forEachLine(in text: String, _ body: (Substring) -> Void) {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        if scalars.first == "\u{FEFF}" {
            index = scalars.index(after: index)
        }
        var lineStart = index
        var lineLength = 0
        var tooLong = false
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" || scalar == "\r" {
                if tooLong == false {
                    body(text[lineStart..<index])
                }
                index = scalars.index(after: index)
                if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" {
                    index = scalars.index(after: index)
                }
                lineStart = index
                lineLength = 0
                tooLong = false
            } else {
                lineLength += 1
                if lineLength > maxLineScalars {
                    tooLong = true
                }
                index = scalars.index(after: index)
            }
        }
        if tooLong == false, lineStart < scalars.endIndex {
            body(text[lineStart..<scalars.endIndex])
        }
    }

    private static func punycodeDomain(_ domain: String) -> String? {
        let parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var encoded: [String] = []
        encoded.reserveCapacity(parts.count)
        for part in parts {
            guard let label = punycodeLabel(part) else { return nil }
            encoded.append(label)
        }
        return encoded.joined(separator: ".")
    }

    private static func punycodeLabel(_ label: Substring) -> String? {
        guard isUnicodeLabel(label) else { return nil }
        let scalars = label.unicodeScalars
        if scalars.allSatisfy(\.isASCII) {
            return String(label)
        }
        guard let encoded = Punycode.encode(scalars.map(\.value)) else { return nil }
        let name = "xn--" + encoded
        guard name.count <= 63 else { return nil }
        guard isValidLabel(Substring(name)) else { return nil }
        return name
    }

    private static func coveredByParent(_ domain: String, _ domains: Set<String>) -> Bool {
        guard let dot = domain.firstIndex(of: ".") else { return false }
        var rest = domain[domain.index(after: dot)...]
        while true {
            if domains.contains(String(rest)) { return true }
            guard let next = rest.firstIndex(of: ".") else { return false }
            rest = rest[rest.index(after: next)...]
        }
    }

    private static func isUnicodeLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard label.first != "-", label.last != "-" else { return false }
        for character in label {
            if character.isASCII {
                let ok = character.isNumber || (character >= "a" && character <= "z") || character == "-"
                if !ok { return false }
            } else if character.isLetter || character.isNumber {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard label.first != "-", label.last != "-" else { return false }
        for character in label {
            let ok = character.isASCII && (character.isNumber || (character >= "a" && character <= "z") || character == "-")
            if !ok { return false }
        }
        return true
    }
}

/// RFC 3492 punycode, basic code points left in place. No `xn--` prefix.
enum Punycode {
    static func encode(_ codePoints: [UInt32]) -> String? {
        let base = 36
        let tmin = 1
        let tmax = 26
        let skew = 38
        let damp = 700
        let initialBias = 72
        let initialN: UInt32 = 128

        var output = ""
        var basicCount = 0
        for point in codePoints where point < 128 {
            guard let scalar = UnicodeScalar(point) else { return nil }
            output.append(Character(scalar))
            basicCount += 1
        }
        if basicCount == codePoints.count {
            return output
        }
        var handled = basicCount
        if basicCount > 0 {
            output.append("-")
        }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < codePoints.count {
            var minimum = UInt32.max
            for point in codePoints where point >= n && point < minimum {
                minimum = point
            }
            if minimum == UInt32.max { return nil }
            let span = handled + 1
            let gap = Int(minimum &- n)
            if span == 0 || gap > (Int.max - delta) / span { return nil }
            delta += gap * span
            n = minimum
            for point in codePoints {
                if point < n {
                    if delta == Int.max { return nil }
                    delta += 1
                }
                if point == n {
                    var q = delta
                    var k = base
                    while true {
                        let t: Int
                        if k <= bias {
                            t = tmin
                        } else if k >= bias + tmax {
                            t = tmax
                        } else {
                            t = k - bias
                        }
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(
                        delta: delta,
                        numPoints: handled + 1,
                        firstTime: handled == basicCount,
                        base: base,
                        tmin: tmin,
                        tmax: tmax,
                        skew: skew,
                        damp: damp
                    )
                    delta = 0
                    handled += 1
                }
            }
            if delta == Int.max { return nil }
            delta += 1
            n += 1
        }
        return output
    }

    private static func adapt(
        delta: Int,
        numPoints: Int,
        firstTime: Bool,
        base: Int,
        tmin: Int,
        tmax: Int,
        skew: Int,
        damp: Int
    ) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }

    private static func digit(_ value: Int) -> Character {
        if value < 26 {
            return Character(UnicodeScalar(UInt32(value) + 97)!)
        }
        return Character(UnicodeScalar(UInt32(value - 26) + 48)!)
    }
}
