// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore
#if canImport(WebKit)
import WebKit
#endif

final class WebContentDefaultsTests: XCTestCase {
    func testElementFullscreenIsOn() {
        XCTAssertTrue(WebContentDefaults.elementFullscreenEnabled)
        XCTAssertFalse(WebContentDefaults.javaScriptCanOpenWindowsAutomatically)
    }

    #if canImport(WebKit)
    @MainActor
    func testConfigurationEnablesElementFullscreen() {
        let configuration = WKWebViewConfiguration()
        WebContentDefaults.apply(to: configuration.preferences)
        XCTAssertTrue(configuration.preferences.isElementFullscreenEnabled)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @MainActor
    func testPopupConfigurationKeepsElementFullscreen() {
        // WebKit hands createWebViewWith a copy of the opener's configuration.
        let opener = WKWebViewConfiguration()
        WebContentDefaults.apply(to: opener.preferences)
        guard let copy = opener.copy() as? WKWebViewConfiguration else {
            return XCTFail("configuration copy")
        }
        WebContentDefaults.apply(to: copy.preferences)
        XCTAssertTrue(copy.preferences.isElementFullscreenEnabled)
    }
    #endif

    func testHostsDoNotTakeAFullscreenWebView() {
        XCTAssertFalse(FullscreenHostingPolicy.shouldMove(isChildOfTarget: false, inElementFullscreen: true))
        XCTAssertFalse(FullscreenHostingPolicy.shouldMove(isChildOfTarget: true, inElementFullscreen: true))
        XCTAssertTrue(FullscreenHostingPolicy.shouldMove(isChildOfTarget: false, inElementFullscreen: false))
        XCTAssertFalse(FullscreenHostingPolicy.shouldMove(isChildOfTarget: true, inElementFullscreen: false))
    }

    func testRepinAfterFullscreenOnlyWhenPinsAreMissing() {
        XCTAssertTrue(FullscreenHostingPolicy.shouldRepin(isChildOfTarget: true, pinnedEdges: 0, inElementFullscreen: false))
        XCTAssertFalse(FullscreenHostingPolicy.shouldRepin(isChildOfTarget: true, pinnedEdges: 4, inElementFullscreen: false))
        XCTAssertFalse(FullscreenHostingPolicy.shouldRepin(isChildOfTarget: true, pinnedEdges: 0, inElementFullscreen: true))
        XCTAssertFalse(FullscreenHostingPolicy.shouldRepin(isChildOfTarget: false, pinnedEdges: 0, inElementFullscreen: false))
    }
}
