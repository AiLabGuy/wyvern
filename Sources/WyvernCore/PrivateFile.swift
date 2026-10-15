// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Application Support files that hold bookmarks, permissions, or list state.
/// The directory is `0700` and the file is `0600`, so the umask cannot leave them group-readable.
public enum PrivateFile {
    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard url.path.withCString({ chmod($0, 0o700) }) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Replace `url` with `data`. An existing file is rewritten. `fchmod` forces `0600`.
    public static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let temporary = url.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        let fd = temporary.path.withCString { open($0, O_CREAT | O_TRUNC | O_WRONLY, mode_t(0o600)) }
        guard fd >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { _ = close(fd) }
        if fchmod(fd, mode_t(0o600)) != 0 {
            throw CocoaError(.fileWriteNoPermission)
        }
        var remaining = data
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                #if canImport(Darwin)
                return Darwin.write(fd, base, buffer.count)
                #else
                return Glibc.write(fd, base, buffer.count)
                #endif
            }
            if wrote < 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            if wrote == 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            remaining.removeFirst(wrote)
        }
        if fsync(fd) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in
                rename(source, destination)
            }
        }
        if renamed != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        if url.path.withCString({ chmod($0, 0o600) }) != 0 {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public static func tightenFile(_ url: URL) {
        _ = url.path.withCString { chmod($0, 0o600) }
    }
}
