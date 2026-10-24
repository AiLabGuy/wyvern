// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// One host (plus optional port) paired with a leaf-certificate SHA-256 fingerprint.
public struct ServerTrustAllowKey: Hashable, Equatable, Sendable {
    public var host: String
    public var port: Int?
    public var fingerprintSHA256: String

    public init(host: String, port: Int? = nil, fingerprintSHA256: String) {
        self.host = host.lowercased()
        self.port = port
        self.fingerprintSHA256 = fingerprintSHA256.lowercased()
    }

    public var displayHost: String {
        if let port {
            return "\(host):\(port)"
        }
        return host
    }
}

/// Process-lifetime allowlist for certificates the person explicitly continued past.
/// Not persisted. Never accepts every certificate globally.
public final class ServerTrustAllowlist: @unchecked Sendable {
    public static let shared = ServerTrustAllowlist()

    private var allowed: Set<ServerTrustAllowKey> = []
    private let lock = NSLock()

    public init() {}

    public func contains(_ key: ServerTrustAllowKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed.contains(key)
    }

    public func allow(_ key: ServerTrustAllowKey) {
        lock.lock()
        allowed.insert(key)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        allowed.removeAll()
        lock.unlock()
    }

#if canImport(CryptoKit)
    /// SHA-256 of certificate DER, lowercase hex.
    public static func fingerprintSHA256(of certificateDER: Data) -> String {
        let digest = SHA256.hash(data: certificateDER)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
#endif

#if canImport(Security) && canImport(CryptoKit)
    /// SHA-256 of the leaf certificate DER, lowercase hex.
    public static func fingerprintSHA256(of certificate: SecCertificate) -> String? {
        let data = SecCertificateCopyData(certificate) as Data
        return fingerprintSHA256(of: data)
    }

    public static func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return nil
        }
        return chain.first
    }

    public static func key(host: String, port: Int?, trust: SecTrust) -> ServerTrustAllowKey? {
        guard let leaf = leafCertificate(from: trust),
              let fp = fingerprintSHA256(of: leaf) else {
            return nil
        }
        return ServerTrustAllowKey(host: host, port: port, fingerprintSHA256: fp)
    }
#endif
}

/// Human-readable fields for the certificate warning alert.
public struct ServerTrustCertificateInfo: Equatable, Sendable {
    public var subjectSummary: String?
    public var issuerSummary: String?
    public var notAfter: Date?
    public var fingerprintSHA256: String?

    public init(
        subjectSummary: String? = nil,
        issuerSummary: String? = nil,
        notAfter: Date? = nil,
        fingerprintSHA256: String? = nil
    ) {
        self.subjectSummary = subjectSummary
        self.issuerSummary = issuerSummary
        self.notAfter = notAfter
        self.fingerprintSHA256 = fingerprintSHA256
    }

#if canImport(Security) && canImport(CryptoKit)
    public static func from(trust: SecTrust) -> ServerTrustCertificateInfo {
        guard let leaf = ServerTrustAllowlist.leafCertificate(from: trust) else {
            return ServerTrustCertificateInfo()
        }
        let subject = SecCertificateCopySubjectSummary(leaf) as String?
        let fingerprint = ServerTrustAllowlist.fingerprintSHA256(of: leaf)
        var issuer: String?
        var notAfter: Date?
        let keys = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotAfter
        ] as CFArray
        var error: Unmanaged<CFError>?
        if let values = SecCertificateCopyValues(leaf, keys, &error) as? [CFString: Any] {
            if let issuerDict = values[kSecOIDX509V1IssuerName] as? [CFString: Any],
               let sections = issuerDict[kSecPropertyKeyValue] as? [[CFString: Any]] {
                var cn: String?
                var org: String?
                for section in sections {
                    let label = section[kSecPropertyKeyLabel] as? String
                    let value = section[kSecPropertyKeyValue] as? String
                    if label == "Common Name" {
                        cn = value
                    } else if label == "Organization" || label == "Organizational Unit Name" {
                        org = org ?? value
                    }
                }
                issuer = cn ?? org
            }
            if let notAfterDict = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any] {
                if let date = notAfterDict[kSecPropertyKeyValue] as? Date {
                    notAfter = date
                } else if let number = notAfterDict[kSecPropertyKeyValue] as? NSNumber {
                    notAfter = Date(timeIntervalSinceReferenceDate: number.doubleValue)
                }
            }
        }
        return ServerTrustCertificateInfo(
            subjectSummary: subject,
            issuerSummary: issuer,
            notAfter: notAfter,
            fingerprintSHA256: fingerprint
        )
    }
#endif

    public func alertBody(hostDisplay: String) -> String {
        var lines: [String] = [
            "\(AppInfo.displayName) could not verify the identity of \"\(hostDisplay)\".",
            "The certificate may be self-signed, expired, or issued for a different name."
        ]
        if let subjectSummary, !subjectSummary.isEmpty {
            lines.append("Certificate: \(subjectSummary)")
        }
        if let issuerSummary, !issuerSummary.isEmpty {
            lines.append("Issuer: \(issuerSummary)")
        }
        if let notAfter {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append("Expires: \(formatter.string(from: notAfter))")
        }
        if let fingerprintSHA256, fingerprintSHA256.count >= 16 {
            let short = fingerprintSHA256.prefix(16)
            lines.append("Fingerprint (SHA-256): \(short)…")
        }
        lines.append("Only continue if you trust this server.")
        return lines.joined(separator: "\n")
    }
}
