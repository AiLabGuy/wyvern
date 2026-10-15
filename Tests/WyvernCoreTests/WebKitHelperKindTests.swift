// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class WebKitHelperKindTests: XCTestCase {
    func testClassifyPrefersWebContentThenNetworkingThenGPU() {
        XCTAssertEqual(
            WebKitHelperKind.classify(nameOrPath: "com.apple.WebKit.WebContent"),
            .webContent
        )
        XCTAssertEqual(
            WebKitHelperKind.classify(nameOrPath: "com.apple.WebKit.Networking"),
            .networking
        )
        XCTAssertEqual(
            WebKitHelperKind.classify(nameOrPath: "com.apple.WebKit.GPU"),
            .gpu
        )
        let path = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        XCTAssertEqual(WebKitHelperKind.classify(nameOrPath: path), .webContent)
        XCTAssertNil(WebKitHelperKind.classify(nameOrPath: "com.apple.WebKit"))
        XCTAssertNil(WebKitHelperKind.classify(nameOrPath: "Safari"))
    }

    func testIsWebKitHelperAcceptsTruncatedProcNameAndFullPath() {
        XCTAssertTrue(WebKitHelperKind.isWebKitHelper(name: "com.apple.WebKit", path: ""))
        XCTAssertTrue(
            WebKitHelperKind.isWebKitHelper(
                name: "",
                path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
            )
        )
        XCTAssertFalse(WebKitHelperKind.isWebKitHelper(name: "Wyvern", path: "/Applications/App.app/Contents/MacOS/Wyvern"))
        XCTAssertFalse(WebKitHelperKind.isWebKitHelper(name: "", path: ""))
    }
}
