// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Kind of a browser tab. Web and terminal tabs share one strip; hide flags filter it.
public enum TabKind: String, Codable, Equatable, Sendable {
    case web
    case terminal
}

/// Derived from the two hide toggles. Callers that list tabs consult `allows`.
public struct TabVisibility: Equatable, Sendable {
    public var hideWebTabs: Bool
    public var hideTerminalTabs: Bool

    public init(hideWebTabs: Bool, hideTerminalTabs: Bool) {
        self.hideWebTabs = hideWebTabs
        self.hideTerminalTabs = hideTerminalTabs
    }

    public func allows(_ kind: TabKind) -> Bool {
        switch kind {
        case .web:
            return !hideWebTabs
        case .terminal:
            return !hideTerminalTabs
        }
    }
}
