// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import Foundation
import WebKit

extension Notification.Name {
    static let wyvernCookieRulesDidChange = Notification.Name("\(AppInfo.bundleIdentifier).cookieRulesDidChange")
}

/// Cookie store policy plus a compiled content rule list for new web views.
@MainActor
final class CookiePolicyController {
    static let shared = CookiePolicyController()

    private(set) var policy: CookiePolicy = .allowAll
    private(set) var ruleList: WKContentRuleList?
    private var generation = 0

    func apply(_ policy: CookiePolicy) {
        self.policy = policy
        applyStorePolicy(policy)
        generation += 1
        let token = generation
        guard let json = policy.contentRuleListJSON else {
            ruleList = nil
            ContentRuleCoordinator.shared.setCookieList(nil)
            NotificationCenter.default.post(name: .wyvernCookieRulesDidChange, object: nil)
            return
        }
        let identifier = "wyvern.cookie-rules.\(policy.rawValue)"
        guard let store = WKContentRuleListStore.default() else {
            ruleList = nil
            ContentRuleCoordinator.shared.setCookieList(nil)
            NotificationCenter.default.post(name: .wyvernCookieRulesDidChange, object: nil)
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.generation else { return }
                    self.ruleList = list
                    ContentRuleCoordinator.shared.setCookieList(list)
                    NotificationCenter.default.post(name: .wyvernCookieRulesDidChange, object: nil)
                }
            }
        }
    }

    /// Installs the cookie list and any block lists. Does not call `removeAllContentRuleLists`.
    func install(on configuration: WKWebViewConfiguration) {
        ContentRuleCoordinator.shared.install(on: configuration)
    }

    private func applyStorePolicy(_ policy: CookiePolicy) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        if #available(macOS 14.0, *) {
            // Leave the type implicit: the SDK names it WKCookiePolicy or WKHTTPCookieStore.CookiePolicy.
            if policy.disallowsHTTPCookies {
                store.setCookiePolicy(.disallow) { }
            } else {
                store.setCookiePolicy(.allow) { }
            }
        }
    }
}
