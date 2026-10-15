// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import Foundation

/// One entry in the window's tab strip. Web, terminal, and DevTools tabs share this order.
enum SessionTab {
    case web(BrowserTab)
    case terminal(TerminalTab)
    case devtools(DevToolsTab)

    var id: UUID {
        switch self {
        case .web(let tab):
            return tab.id
        case .terminal(let tab):
            return tab.id
        case .devtools(let tab):
            return tab.id
        }
    }

    var kind: TabKind {
        switch self {
        case .web:
            return .web
        case .terminal:
            return .terminal
        case .devtools:
            return .devtools
        }
    }
}
