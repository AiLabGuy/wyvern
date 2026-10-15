// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import Foundation
import WebKit

/// Installs the cookie rule list and the block-list rule lists together.
/// `removeAllContentRuleLists` would drop whichever feature installed first.
/// Lists are remembered per `WKUserContentController`. There is no public API
/// to read the controller's lists back, and a global cap would drop a list
/// that a live tab still has installed.
@MainActor
final class ContentRuleCoordinator {
    static let shared = ContentRuleCoordinator()

    private var cookieList: WKContentRuleList?
    private var blockLists: [WKContentRuleList] = []
    private var installed: [ObjectIdentifier: [WKContentRuleList]] = [:]

    func setCookieList(_ list: WKContentRuleList?) {
        cookieList = list
    }

    func setBlockLists(_ lists: [WKContentRuleList]) {
        blockLists = lists
    }

    func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        let key = ObjectIdentifier(controller)
        for list in installed[key] ?? [] {
            controller.remove(list)
        }
        if let cookieList {
            controller.add(cookieList)
        }
        for list in blockLists {
            controller.add(list)
        }
        var tracked: [WKContentRuleList] = []
        if let cookieList {
            tracked.append(cookieList)
        }
        tracked.append(contentsOf: blockLists)
        installed[key] = tracked
    }

    /// Drops the record for a controller that is going away. Call from tab shutdown.
    func forget(_ configuration: WKWebViewConfiguration) {
        installed.removeValue(forKey: ObjectIdentifier(configuration.userContentController))
    }
}
