// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// JSON bookmark file used by some desktop browsers (`Bookmarks` in a profile folder).
/// Roots `bookmark_bar`, `other`, and `synced` are imported. ICON fields are ignored.
public enum BrowserFamilyBookmarkParser {
    private struct FileObject: Decodable {
        var roots: Roots?
    }

    private struct Roots: Decodable {
        var bookmark_bar: Node?
        var other: Node?
        var synced: Node?
    }

    private struct Node: Decodable {
        var name: String?
        var type: String?
        var url: String?
        var children: [Node]?
        var date_added: String?
    }

    public static func parse(data: Data) throws -> [ImportedNode] {
        guard data.count <= BookmarkImport.maxFileSize else {
            throw BookmarkImportError.fileTooLarge
        }
        let file: FileObject
        do {
            file = try JSONDecoder().decode(FileObject.self, from: data)
        } catch {
            throw BookmarkImportError.unreadable
        }
        var nodes: [ImportedNode] = []
        if let bar = file.roots?.bookmark_bar {
            nodes.append(folder(from: bar, fallback: "Bookmarks Bar", depth: 1))
        }
        if let other = file.roots?.other {
            nodes.append(folder(from: other, fallback: "Other Bookmarks", depth: 1))
        }
        if let synced = file.roots?.synced {
            nodes.append(folder(from: synced, fallback: "Mobile Bookmarks", depth: 1))
        }
        return nodes
    }

    private static func folder(from node: Node, fallback: String, depth: Int) -> ImportedNode {
        let title = BookmarkText.sanitizeTitle(node.name ?? fallback)
        return .folder(title: title.isEmpty ? fallback : title, children: convert(node.children ?? [], depth: depth))
    }

    private static func convert(_ nodes: [Node], depth: Int) -> [ImportedNode] {
        var result: [ImportedNode] = []
        for node in nodes {
            let kind = (node.type ?? "").lowercased()
            if kind == "folder" {
                let title = BookmarkText.sanitizeTitle(node.name ?? "Folder")
                let children = convert(node.children ?? [], depth: depth + 1)
                if depth >= BookmarkImport.maxFolderDepth {
                    result.append(contentsOf: children)
                } else {
                    result.append(.folder(title: title.isEmpty ? "Folder" : title, children: children))
                }
            } else if kind == "url" {
                let title = BookmarkText.sanitizeTitle(node.name ?? "")
                let url = node.url ?? ""
                result.append(.bookmark(title: title, url: url, added: parseDate(node.date_added)))
            }
        }
        return result
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, let value = Double(raw), value > 0 else { return nil }
        // Microseconds since 1601-01-01 when the value is large; otherwise unix seconds.
        if value > 10_000_000_000 {
            let windowsEpoch: Double = 11_644_473_600
            return Date(timeIntervalSince1970: value / 1_000_000 - windowsEpoch)
        }
        return Date(timeIntervalSince1970: value)
    }
}
