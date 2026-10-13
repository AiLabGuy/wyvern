// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct NodeTally: Equatable, Sendable {
    public var bookmarks: Int
    public var folders: Int

    public init(bookmarks: Int = 0, folders: Int = 0) {
        self.bookmarks = bookmarks
        self.folders = folders
    }

    public static func of(_ nodes: [ImportedNode]) -> NodeTally {
        var tally = NodeTally()
        walk(nodes, into: &tally)
        return tally
    }

    private static func walk(_ nodes: [ImportedNode], into tally: inout NodeTally) {
        for node in nodes {
            switch node {
            case .folder(_, let children):
                tally.folders += 1
                walk(children, into: &tally)
            case .bookmark:
                tally.bookmarks += 1
            }
        }
    }
}
