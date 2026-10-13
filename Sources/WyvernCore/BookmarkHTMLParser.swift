// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Netscape bookmark HTML. Treated as untrusted text. Never loaded in a web view.
/// Keeps HREF, title text, ADD_DATE, and H3/DL folders. ICON data is ignored.
public enum BookmarkHTMLParser {
    private struct Frame {
        var title: String
        var children: [ImportedNode]
    }

    public static func parse(data: Data) throws -> [ImportedNode] {
        guard data.count <= BookmarkImport.maxFileSize else {
            throw BookmarkImportError.fileTooLarge
        }
        guard let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw BookmarkImportError.unreadable
        }
        return parse(html: raw)
    }

    public static func parse(html: String) -> [ImportedNode] {
        var frames: [Frame] = [Frame(title: "", children: [])]
        var pendingFolder: String?
        var depth = 0
        var flatten = 0
        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<" else {
                index = html.index(after: index)
                continue
            }
            let (tag, attrs, next, isClose) = readTag(html, from: index)
            index = next
            let name = tag.lowercased()
            if name == "dl" {
                if isClose {
                    if depth > 0 { depth -= 1 }
                    if flatten > 0 {
                        flatten -= 1
                    } else if frames.count > 1 {
                        let frame = frames.removeLast()
                        let title = frame.title.isEmpty ? "Folder" : frame.title
                        frames[frames.count - 1].children.append(.folder(title: title, children: frame.children))
                    }
                } else {
                    depth += 1
                    if let title = pendingFolder {
                        pendingFolder = nil
                        if depth <= BookmarkImport.maxFolderDepth {
                            frames.append(Frame(title: title, children: []))
                        } else {
                            flatten += 1
                        }
                    }
                }
                continue
            }
            if name == "h3" && !isClose {
                let (text, after) = readUntilClose(html, from: index, tag: "h3")
                index = after
                pendingFolder = BookmarkText.sanitizeTitle(BookmarkText.decodeEntities(text))
                continue
            }
            if name == "a" && !isClose {
                let href = attribute(attrs, "href")
                let added = parseAddDate(attribute(attrs, "add_date"))
                let (text, after) = readUntilClose(html, from: index, tag: "a")
                index = after
                let title = BookmarkText.sanitizeTitle(BookmarkText.decodeEntities(text))
                let url = BookmarkText.decodeEntities(href)
                frames[frames.count - 1].children.append(.bookmark(title: title, url: url, added: added))
            }
        }
        while frames.count > 1 {
            let frame = frames.removeLast()
            let title = frame.title.isEmpty ? "Folder" : frame.title
            frames[frames.count - 1].children.append(.folder(title: title, children: frame.children))
        }
        return frames.first?.children ?? []
    }

    private static func readTag(
        _ html: String,
        from start: String.Index
    ) -> (name: String, attrs: String, next: String.Index, isClose: Bool) {
        var index = html.index(after: start)
        var isClose = false
        if index < html.endIndex, html[index] == "/" {
            isClose = true
            index = html.index(after: index)
        }
        let nameStart = index
        while index < html.endIndex {
            let ch = html[index]
            if ch == " " || ch == "\n" || ch == "\r" || ch == "\t" || ch == ">" || ch == "/" {
                break
            }
            index = html.index(after: index)
        }
        let name = String(html[nameStart..<index])
        let attrStart = index
        var inQuote: Character?
        while index < html.endIndex {
            let ch = html[index]
            if let quote = inQuote {
                if ch == quote { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == ">" {
                let attrs = String(html[attrStart..<index])
                return (name, attrs, html.index(after: index), isClose)
            }
            index = html.index(after: index)
        }
        return (name, String(html[attrStart..<index]), index, isClose)
    }

    private static func readUntilClose(
        _ html: String,
        from start: String.Index,
        tag: String
    ) -> (String, String.Index) {
        let close = "</\(tag)"
        if let range = html.range(of: close, options: [.caseInsensitive], range: start..<html.endIndex) {
            let text = String(html[start..<range.lowerBound])
            if let gt = html.range(of: ">", range: range.lowerBound..<html.endIndex) {
                return (text, gt.upperBound)
            }
            return (text, html.endIndex)
        }
        return (String(html[start...]), html.endIndex)
    }

    private static func attribute(_ attrs: String, _ name: String) -> String {
        let lower = attrs.lowercased()
        let needle = name.lowercased() + "="
        guard let match = lower.range(of: needle) else { return "" }
        let offset = lower.distance(from: lower.startIndex, to: match.upperBound)
        guard offset <= attrs.count else { return "" }
        var cursor = attrs.index(attrs.startIndex, offsetBy: offset)
        guard cursor < attrs.endIndex else { return "" }
        var quote: Character?
        if attrs[cursor] == "\"" || attrs[cursor] == "'" {
            quote = attrs[cursor]
            cursor = attrs.index(after: cursor)
        }
        let valueStart = cursor
        while cursor < attrs.endIndex {
            let ch = attrs[cursor]
            if let quote {
                if ch == quote { break }
            } else if ch == " " || ch == ">" {
                break
            }
            cursor = attrs.index(after: cursor)
        }
        return String(attrs[valueStart..<cursor])
    }

    private static func parseAddDate(_ raw: String) -> Date? {
        guard let value = TimeInterval(raw), value > 0 else { return nil }
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000_000)
        }
        return Date(timeIntervalSince1970: value)
    }
}
