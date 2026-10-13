// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One entry from a zip central directory, after bounds checks.
public struct ZipEntryInfo: Equatable, Sendable {
    public var name: String
    public var method: UInt16
    public var compressedSize: UInt32
    public var uncompressedSize: UInt32
    public var localHeaderOffset: UInt32
}

/// Reads a zip's central directory without extracting anything, and refuses archives
/// whose entries could escape the extraction folder or are not plain files.
///
/// Accepted: one disk, no ZIP64, no encryption, stored or deflated entries, and exactly
/// the allowed set of root-level names, each a regular file. Every local header must carry
/// the same name as its central directory record, so an extractor that reads either one
/// sees the same names.
public enum UpdateZipInspector {
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let localSignature: UInt32 = 0x0403_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let eocdSize = 22
    private static let centralSize = 46
    private static let localSize = 30
    private static let maxEntries = 16
    /// Unpacked size cap across all members.
    public static let maxTotalUncompressed: UInt64 = 1024 * 1024 * 1024

    public static func inspect(zipAt url: URL, allowed: Set<String>) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw UpdatePackageError.zipMalformed
        }
        _ = try inspect(data, allowed: allowed)
    }

    @discardableResult
    public static func inspect(_ data: Data, allowed: Set<String>) throws -> [ZipEntryInfo] {
        let entries = try centralDirectory(data)
        var seen: Set<String> = []
        var total: UInt64 = 0
        for entry in entries {
            try checkName(entry.name)
            guard seen.insert(entry.name).inserted else {
                throw UpdatePackageError.duplicateEntry(entry.name)
            }
            guard allowed.contains(entry.name) else {
                throw UpdatePackageError.unexpectedEntry(entry.name)
            }
            total += UInt64(entry.uncompressedSize)
        }
        guard total <= maxTotalUncompressed else { throw UpdatePackageError.tooLarge }
        guard seen == allowed else { throw UpdatePackageError.missingMember }
        return entries
    }

    /// A member name must be a single plain path component.
    public static func checkName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\\")
            || name.hasPrefix("~") || name.contains(":") {
            throw UpdatePackageError.pathTraversal(name)
        }
        guard name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw UpdatePackageError.pathTraversal(name)
        }
    }

    public static func centralDirectory(_ data: Data) throws -> [ZipEntryInfo] {
        let count = data.count
        guard count >= eocdSize else { throw UpdatePackageError.zipMalformed }
        // End record: the last signature whose comment runs exactly to the end of the file.
        var eocd = -1
        let lowest = max(0, count - eocdSize - 0xFFFF)
        var position = count - eocdSize
        while position >= lowest {
            if u32(data, position) == eocdSignature,
               let commentLength = u16(data, position + 20),
               position + eocdSize + Int(commentLength) == count {
                eocd = position
                break
            }
            position -= 1
        }
        guard eocd >= 0 else { throw UpdatePackageError.zipMalformed }
        if eocd >= 20, u32(data, eocd - 20) == zip64LocatorSignature {
            throw UpdatePackageError.unsupportedEntry("zip64")
        }
        guard let disk = u16(data, eocd + 4),
              let cdDisk = u16(data, eocd + 6),
              let entriesOnDisk = u16(data, eocd + 8),
              let entriesTotal = u16(data, eocd + 10),
              let cdSize = u32(data, eocd + 12),
              let cdOffset = u32(data, eocd + 16) else {
            throw UpdatePackageError.zipMalformed
        }
        guard disk == 0, cdDisk == 0, entriesOnDisk == entriesTotal else {
            throw UpdatePackageError.unsupportedEntry("multi-disk")
        }
        guard entriesTotal != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else {
            throw UpdatePackageError.unsupportedEntry("zip64")
        }
        guard entriesTotal > 0, Int(entriesTotal) <= maxEntries else { throw UpdatePackageError.zipMalformed }
        // The central directory sits directly before the end record. Nothing is hidden between them.
        guard Int(cdOffset) + Int(cdSize) == eocd else { throw UpdatePackageError.zipMalformed }

        var entries: [ZipEntryInfo] = []
        var cursor = Int(cdOffset)
        for _ in 0..<Int(entriesTotal) {
            guard cursor + centralSize <= eocd, u32(data, cursor) == centralSignature,
                  let madeBy = u16(data, cursor + 4),
                  let flags = u16(data, cursor + 8),
                  let method = u16(data, cursor + 10),
                  let compressed = u32(data, cursor + 20),
                  let uncompressed = u32(data, cursor + 24),
                  let nameLength = u16(data, cursor + 28),
                  let extraLength = u16(data, cursor + 30),
                  let commentLength = u16(data, cursor + 32),
                  let startDisk = u16(data, cursor + 34),
                  let external = u32(data, cursor + 38),
                  let localOffset = u32(data, cursor + 42) else {
                throw UpdatePackageError.zipMalformed
            }
            let nameStart = cursor + centralSize
            let next = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard nameLength > 0, next <= eocd else { throw UpdatePackageError.zipMalformed }
            let nameBytes = bytes(data, nameStart, Int(nameLength))
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw UpdatePackageError.zipMalformed
            }
            guard startDisk == 0 else { throw UpdatePackageError.unsupportedEntry(name) }
            // Bit 0: encrypted. Bit 6: strong encryption. Bit 13: masked central directory.
            guard flags & 0x0001 == 0, flags & 0x0040 == 0, flags & 0x2000 == 0 else {
                throw UpdatePackageError.unsupportedEntry(name)
            }
            guard method == 0 || method == 8 else { throw UpdatePackageError.unsupportedEntry(name) }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw UpdatePackageError.unsupportedEntry(name)
            }
            try checkFileType(madeBy: madeBy, external: external, name: name)
            try checkLocalHeader(
                data,
                offset: Int(localOffset),
                name: nameBytes,
                compressedSize: Int(compressed),
                limit: Int(cdOffset)
            )
            entries.append(ZipEntryInfo(
                name: name,
                method: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            ))
            cursor = next
        }
        guard cursor == eocd else { throw UpdatePackageError.zipMalformed }
        return entries
    }

    /// Unix-made entries carry the file mode in the high 16 bits of the external attributes.
    /// Only regular files (or an unset type) pass. DOS-made entries must not be directories.
    private static func checkFileType(madeBy: UInt16, external: UInt32, name: String) throws {
        let host = madeBy >> 8
        if host == 3 || host == 19 {
            let type = (external >> 16) & 0o170000
            if type == 0o120000 {
                throw UpdatePackageError.symlinkRejected
            }
            if type != 0 && type != 0o100000 {
                throw UpdatePackageError.notRegularFile
            }
        }
        if external & 0x10 != 0 || name.hasSuffix("/") {
            throw UpdatePackageError.notRegularFile
        }
    }

    private static func checkLocalHeader(
        _ data: Data,
        offset: Int,
        name: [UInt8],
        compressedSize: Int,
        limit: Int
    ) throws {
        guard offset + localSize <= limit, u32(data, offset) == localSignature,
              let flags = u16(data, offset + 6),
              let nameLength = u16(data, offset + 26),
              let extraLength = u16(data, offset + 28) else {
            throw UpdatePackageError.zipMalformed
        }
        guard flags & 0x0001 == 0 else { throw UpdatePackageError.unsupportedEntry("encrypted") }
        let nameStart = offset + localSize
        let dataStart = nameStart + Int(nameLength) + Int(extraLength)
        guard Int(nameLength) == name.count, dataStart + compressedSize <= limit else {
            throw UpdatePackageError.zipMalformed
        }
        guard bytes(data, nameStart, Int(nameLength)) == name else {
            throw UpdatePackageError.zipMalformed
        }
    }

    /// Callers have already bounds-checked `offset + count` against `data.count`.
    private static func bytes(_ data: Data, _ offset: Int, _ count: Int) -> [UInt8] {
        let base = data.startIndex + offset
        return [UInt8](data[base..<(base + count)])
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
