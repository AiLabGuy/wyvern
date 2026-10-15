// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// SHA-256 without CryptoKit, so list hashes stay testable on non-Apple hosts.
enum BlockListHash {
    static func hex(_ data: Data) -> String {
        BlockListSHA256.hex(data)
    }

    static func hex(_ text: String) -> String {
        hex(Data(text.utf8))
    }

    /// Hash of the on-disk domain cache: one domain per line, trailing newline when non-empty.
    static func contentHash(domains: [String]) -> String {
        hex(cacheText(domains: domains))
    }

    static func cacheText(domains: [String]) -> String {
        guard !domains.isEmpty else { return "" }
        return domains.joined(separator: "\n") + "\n"
    }

    /// Changes when the domain set, allowlist, rule template, or chunk limit changes.
    /// `templateVersion` is `ContentRuleCompiler.templateVersion`. Bump that when the compiler changes.
    static func compileHash(
        domains: [String],
        allowlist: [String],
        templateVersion: String,
        ruleLimit: Int
    ) -> String {
        var text = "v2\n"
        text.reserveCapacity(domains.count * 24 + allowlist.count * 24 + templateVersion.count + 24)
        text += templateVersion
        text += "\n"
        text += String(ruleLimit)
        text += "\n"
        text += domains.joined(separator: "\n")
        text += "\n--\n"
        text += allowlist.joined(separator: "\n")
        return hex(text)
    }
}

/// Compact SHA-256. Public tests cover the empty string and "abc".
enum BlockListSHA256 {
    static func hex(_ data: Data) -> String {
        hash([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var bytes = message
        let bitCount = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        var offset = 0
        while offset < bytes.count {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                w[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            var f = h5
            var g = h6
            var h = h7
            for index in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ choose &+ k[index] &+ w[index]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
            offset += 64
        }

        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
}
