// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

public struct PlacesImport: Equatable, Sendable {
    public var nodes: [ImportedNode]
    public var copiedWAL: Bool
    public var copiedSHM: Bool
    public var tempDirectoryPath: String

    public init(nodes: [ImportedNode], copiedWAL: Bool, copiedSHM: Bool, tempDirectoryPath: String) {
        self.nodes = nodes
        self.copiedWAL = copiedWAL
        self.copiedSHM = copiedSHM
        self.tempDirectoryPath = tempDirectoryPath
    }
}

/// Reads bookmarks and folders from a copy of a Zen or Firefox `places.sqlite`.
/// The SQL is written from the public `moz_bookmarks` / `moz_places` schema.
/// History, favicons, cookies, and logins are not queried.
public enum PlacesDatabase {
    private struct RawItem {
        var id: Int64
        var type: Int
        var parent: Int64
        var position: Int
        var title: String
        var url: String
    }

    /// Bookmarks (type 1) and folders (type 2) only. Separators (type 3) are omitted.
    public static let bookmarkQuery = """
    SELECT b.id, b.type, b.parent, b.position, b.title, p.url, p.title \
    FROM moz_bookmarks AS b \
    LEFT JOIN moz_places AS p ON b.fk = p.id \
    WHERE b.type IN (1, 2) \
    ORDER BY b.parent, b.position, b.id
    """

    public static func importTree(
        from userPickedURL: URL,
        fileManager: FileManager = .default
    ) throws -> PlacesImport {
        let sqliteURL = try resolveDatabaseURL(userPickedURL, fileManager: fileManager)
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("wyvern-places-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let dest = temp.appendingPathComponent("places.sqlite")
        try fileManager.copyItem(at: sqliteURL, to: dest)
        let copiedWAL = copySidecar(of: sqliteURL, suffix: "-wal", dest: dest, fileManager: fileManager)
        let copiedSHM = copySidecar(of: sqliteURL, suffix: "-shm", dest: dest, fileManager: fileManager)
        if copiedWAL {
            checkpointCopy(dest)
        }
        let nodes = try readTree(from: dest)
        return PlacesImport(
            nodes: nodes,
            copiedWAL: copiedWAL,
            copiedSHM: copiedSHM,
            tempDirectoryPath: temp.path
        )
    }

    public static func resolveDatabaseURL(_ picked: URL, fileManager: FileManager) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: picked.path, isDirectory: &isDirectory) else {
            throw BookmarkImportError.missingPlacesDatabase
        }
        if isDirectory.boolValue {
            let sqlite = picked.appendingPathComponent("places.sqlite")
            guard fileManager.fileExists(atPath: sqlite.path) else {
                throw BookmarkImportError.missingPlacesDatabase
            }
            return sqlite
        }
        return picked
    }

    private static func copySidecar(
        of sqlite: URL,
        suffix: String,
        dest: URL,
        fileManager: FileManager
    ) -> Bool {
        let source = URL(fileURLWithPath: sqlite.path + suffix)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let target = URL(fileURLWithPath: dest.path + suffix)
        try? fileManager.copyItem(at: source, to: target)
        return fileManager.fileExists(atPath: target.path)
    }

    /// Merge WAL contents into the copy so a later immutable open still sees them.
    private static func checkpointCopy(_ sqlite: URL) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        let status = sqlite.path.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return
        }
        sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(handle)
    }

    private static func readTree(from sqlite: URL) throws -> [ImportedNode] {
        var handle: OpaquePointer?
        let uri = sqliteURI(for: sqlite)
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let status = uri.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw BookmarkImportError.sqlite
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, bookmarkQuery, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw BookmarkImportError.sqlite
        }
        defer { sqlite3_finalize(statement) }

        var items: [RawItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let type = Int(sqlite3_column_int(statement, 1))
            if type == 3 { continue }
            let bookmarkTitle = columnText(statement, 4)
            let placeTitle = columnText(statement, 6)
            let title = bookmarkTitle.isEmpty ? placeTitle : bookmarkTitle
            items.append(
                RawItem(
                    id: sqlite3_column_int64(statement, 0),
                    type: type,
                    parent: sqlite3_column_int64(statement, 2),
                    position: Int(sqlite3_column_int(statement, 3)),
                    title: title,
                    url: columnText(statement, 5)
                )
            )
        }
        return assemble(items)
    }

    private static func assemble(_ items: [RawItem]) -> [ImportedNode] {
        var children: [Int64: [RawItem]] = [:]
        for item in items {
            children[item.parent, default: []].append(item)
        }
        for key in children.keys {
            children[key]?.sort {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id < $1.id
            }
        }
        let roots = items.filter { $0.parent == 0 && $0.type == 2 }
        let rootID: Int64
        if let root = roots.min(by: { $0.id < $1.id }) {
            rootID = root.id
        } else if let fallback = items.map(\.parent).min() {
            rootID = fallback
        } else {
            return []
        }
        let top = children[rootID] ?? []
        return top.compactMap { convert($0, children: children, isRootChild: true) }
    }

    private static func convert(
        _ item: RawItem,
        children: [Int64: [RawItem]],
        isRootChild: Bool
    ) -> ImportedNode? {
        if item.type == 2 {
            if isRootChild, item.title.lowercased() == "tags" {
                return nil
            }
            let title: String
            if isRootChild, let mapped = mapRootTitle(item.title) {
                title = mapped
            } else if isRootChild {
                return nil
            } else {
                title = item.title
            }
            let nested = (children[item.id] ?? []).compactMap {
                convert($0, children: children, isRootChild: false)
            }
            return .folder(title: title, children: nested)
        }
        if item.type == 1 {
            return .bookmark(title: item.title, url: item.url, added: nil)
        }
        return nil
    }

    private static func mapRootTitle(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "menu": return "Menu"
        case "toolbar": return "Toolbar"
        case "unfiled": return "Other"
        case "mobile": return "Mobile"
        default: return nil
        }
    }

    private static func sqliteURI(for file: URL) -> String {
        var path = file.standardizedFileURL.path
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:\(encoded)?mode=ro&immutable=1"
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}
