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

    /// Nodes visited before the walk stops. A 10 MB file of nested folders stays under this.
    private static let maxNodes = 500_000

    /// Iterative so a deep tree cannot overflow the stack. Folders past `maxFolderDepth`
    /// are flattened and their bookmarks are kept, matching the HTML importer.
    private static func convert(_ nodes: [Node], depth: Int) -> [ImportedNode] {
        struct Level {
            var nodes: [Node]
            var next: Int
            var depth: Int
            var built: [ImportedNode]
            var title: String
            var isRoot: Bool
        }
        var stack: [Level] = [Level(nodes: nodes, next: 0, depth: depth, built: [], title: "", isRoot: true)]
        var steps = 0
        while let current = stack.last {
            if current.next >= current.nodes.count {
                let done = stack.removeLast()
                if done.isRoot {
                    return done.built
                }
                guard var parent = stack.popLast() else { return done.built }
                if parent.depth >= BookmarkImport.maxFolderDepth {
                    parent.built.append(contentsOf: done.built)
                } else {
                    let title = done.title.isEmpty ? "Folder" : done.title
                    parent.built.append(.folder(title: title, children: done.built))
                }
                stack.append(parent)
                continue
            }
            steps += 1
            if steps > maxNodes {
                var collected: [ImportedNode] = []
                for level in stack {
                    collected.append(contentsOf: level.built)
                }
                return collected
            }
            var frame = stack.removeLast()
            let node = frame.nodes[frame.next]
            frame.next += 1
            let kind = (node.type ?? "").lowercased()
            if kind == "folder" {
                let title = BookmarkText.sanitizeTitle(node.name ?? "Folder")
                stack.append(frame)
                stack.append(Level(
                    nodes: node.children ?? [],
                    next: 0,
                    depth: frame.depth + 1,
                    built: [],
                    title: title.isEmpty ? "Folder" : title,
                    isRoot: false
                ))
            } else if kind == "url" {
                let title = BookmarkText.sanitizeTitle(node.name ?? "")
                frame.built.append(.bookmark(title: title, url: node.url ?? "", added: parseDate(node.date_added)))
                stack.append(frame)
            } else {
                stack.append(frame)
            }
        }
        return []
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
