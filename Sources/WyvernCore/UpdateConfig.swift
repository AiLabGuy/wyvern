// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

#if WYVERN_DEV_UPDATER
public let isDevUpdaterCompiled = true
#else
public let isDevUpdaterCompiled = false
#endif

public enum UpdateTransportPolicy {
    /// Dotted-quad IPv4 in 10/8, 172.16/12, or 192.168/16. Names are never private.
    public static func isPrivateNetworkHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 255 else {
                return false
            }
            octets.append(value)
        }
        let a = octets[0], b = octets[1]
        if a == 10 { return true }
        if a == 192, b == 168 { return true }
        if a == 172, (16...31).contains(b) { return true }
        return false
    }

    /// Plain HTTP needs the dev compile flag, an explicit dev request, and a private IPv4 host.
    public static func allowsHTTP(
        host: String,
        isDevUpdaterCompiled compiled: Bool,
        devSourceRequested: Bool
    ) -> Bool {
        compiled && devSourceRequested && isPrivateNetworkHost(host)
    }

    /// Feed and asset URLs: https, or dev-only http to a private host. No user info.
    public static func checkURL(_ url: URL, allowsDevHTTP: Bool) -> Result<URL, UpdateSourceError> {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return .failure(.malformedURL)
        }
        if url.user != nil || url.password != nil {
            return .failure(.credentialsInURL)
        }
        switch scheme {
        case "https":
            return .success(url)
        case "http":
            guard isDevUpdaterCompiled, allowsDevHTTP else { return .failure(.httpRejected) }
            guard isPrivateNetworkHost(host) else { return .failure(.publicHTTPRejected) }
            return .success(url)
        default:
            return .failure(.malformedURL)
        }
    }

    public static func parseSourceURL(_ raw: String, allowsDevHTTP: Bool) -> Result<URL, UpdateSourceError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyURL) }
        guard !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed) else {
            return .failure(.malformedURL)
        }
        return checkURL(url, allowsDevHTTP: allowsDevHTTP)
    }
}

public enum UpdateVersion {
    /// Dot-separated decimal components, each 1 to 9 digits.
    public static func isValidVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 4 && parts.allSatisfy { part in
            (1...9).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Canonical non-negative decimal: no sign, no leading zero, at most 9 digits.
    public static func isValidBuild(_ text: String) -> Bool {
        guard (1...9).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text) else {
            return false
        }
        return String(value) == text
    }

    public static func isValidCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Strictly newer: marketing version first, then the integer build.
    /// A different commit at the same version and build is not newer.
    public static func isNewer(
        remoteVersion: String,
        remoteBuild: String,
        localVersion: String,
        localBuild: String
    ) -> Bool {
        let versionOrder = compareVersion(remoteVersion, localVersion)
        if versionOrder > 0 { return true }
        if versionOrder < 0 { return false }
        let remoteNumber = Int(remoteBuild) ?? -1
        let localNumber = Int(localBuild) ?? -1
        return remoteNumber > localNumber
    }

    public static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }
}

public struct ChecksumRecord: Equatable, Sendable {
    public var hex: String
    public var fileName: String

    public init(hex: String, fileName: String) {
        self.hex = hex
        self.fileName = fileName
    }
}

public enum SHA256Util {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseChecksumFile(_ text: String) -> String? {
        parseChecksumRecord(text)?.hex
    }

    /// First line is `hex  filename`. The name is one path component: no slash or backslash.
    public static func parseChecksumRecord(_ text: String) -> ChecksumRecord? {
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: { (c: Character) in c.isNewline }).first.map(String.init) ?? ""
        let parts = line.split(omittingEmptySubsequences: true, whereSeparator: { (c: Character) in c == " " || c == "\t" }).map(String.init)
        guard parts.count == 2 else { return nil }
        let digest = parts[0].lowercased()
        guard digest.count == 64, digest.allSatisfy({ (c: Character) in c.isHexDigit }) else { return nil }
        let name = parts[1]
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            return nil
        }
        return ChecksumRecord(hex: digest, fileName: name)
    }
}
