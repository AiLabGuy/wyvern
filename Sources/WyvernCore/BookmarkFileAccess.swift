// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct BookmarkFileAttributes: Equatable, Sendable {
    public var isSymbolicLink: Bool
    public var isRegularFile: Bool
    public var size: Int64

    public init(isSymbolicLink: Bool, isRegularFile: Bool, size: Int64) {
        self.isSymbolicLink = isSymbolicLink
        self.isRegularFile = isRegularFile
        self.size = size
    }
}

public enum BookmarkFileError: Error, Equatable, Sendable {
    case symlink
    case notRegular
    case tooLarge
    case unreadable
}

public protocol BookmarkFileOpening {
    func attributes(at url: URL) throws -> BookmarkFileAttributes
    func read(at url: URL, maximumBytes: Int) throws -> Data
}

public struct POSIXBookmarkFileOpener: BookmarkFileOpening {
    public init() {}

    public func attributes(at url: URL) throws -> BookmarkFileAttributes {
        var info = stat()
        let rc = url.path.withCString { lstat($0, &info) }
        guard rc == 0 else { throw BookmarkFileError.unreadable }
        let mode = mode_t(info.st_mode)
        let link = (mode & S_IFMT) == S_IFLNK
        let regular = (mode & S_IFMT) == S_IFREG
        return BookmarkFileAttributes(isSymbolicLink: link, isRegularFile: regular, size: Int64(info.st_size))
    }

    public func read(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return data
    }
}

public enum BookmarkFileReader {
    public static let maxBookmarkBytes = 20 * 1024 * 1024

    /// `lstat` first. Symlinks and non-regular files are refused. The bytes are read only after that.
    public static func readBookmarks(at url: URL, opener: BookmarkFileOpening) throws -> Data {
        let attributes = try opener.attributes(at: url)
        if attributes.isSymbolicLink { throw BookmarkFileError.symlink }
        if !attributes.isRegularFile { throw BookmarkFileError.notRegular }
        if attributes.size > maxBookmarkBytes { throw BookmarkFileError.tooLarge }
        let data = try opener.read(at: url, maximumBytes: maxBookmarkBytes)
        if data.count > maxBookmarkBytes { throw BookmarkFileError.tooLarge }
        return data
    }
}

/// Records every path asked to stat or read. Tests use this to prove decoy files stay closed.
public final class RecordingBookmarkOpener: BookmarkFileOpening, @unchecked Sendable {
    public private(set) var opened: [String] = []
    private let inner: BookmarkFileOpening

    public init(inner: BookmarkFileOpening = POSIXBookmarkFileOpener()) {
        self.inner = inner
    }

    public func attributes(at url: URL) throws -> BookmarkFileAttributes {
        opened.append(url.path)
        return try inner.attributes(at: url)
    }

    public func read(at url: URL, maximumBytes: Int) throws -> Data {
        opened.append(url.path)
        return try inner.read(at: url, maximumBytes: maximumBytes)
    }
}
