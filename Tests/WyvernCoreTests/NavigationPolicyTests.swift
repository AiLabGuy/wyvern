// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class NavigationPolicyTests: XCTestCase {
    func testAllowedSchemes() throws {
        for raw in ["https://example.com", "http://example.com", "about:blank", "blob:https://example.com/id"] {
            let url = try XCTUnwrap(URL(string: raw))
            let decision = NavigationPolicy.decide(NavigationRequest(url: url, isMainFrame: true))
            XCTAssertEqual(decision, .allow, raw)
        }
    }

    func testJavascriptAndDataAreCancelled() throws {
        let script = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        let data = try XCTUnwrap(URL(string: "data:text/html,hi"))
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: script, isMainFrame: true)), .cancel)
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: data, isMainFrame: true)), .cancel)
    }

    func testExternalSchemesNeedConfirmation() throws {
        let mail = try XCTUnwrap(URL(string: "mailto:person@example.com"))
        let custom = try XCTUnwrap(URL(string: "customapp://open"))
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: mail, isMainFrame: true)), .confirmExternal)
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: custom, isMainFrame: true)), .confirmExternal)
    }

    func testProductSchemesCannotStartACommand() throws {
        for raw in ["icarus://run?cmd=ls", "wyvern://run", "icarus://", "wyvern://"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: url, isMainFrame: true)), .cancel, raw)
        }
        let custom = try XCTUnwrap(URL(string: "customapp://open"))
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: custom, isMainFrame: true)), .confirmExternal)
    }

    func testFileURLOnlyWhenTyped() throws {
        let typed = try XCTUnwrap(URL(string: "file:///tmp/site/index.html"))
        let same = try XCTUnwrap(URL(string: "file:///tmp/site/index.html"))
        let otherPage = try XCTUnwrap(URL(string: "file:///tmp/site/other.html"))
        let sibling = try XCTUnwrap(URL(string: "file:///tmp/site/app.js"))
        let outside = try XCTUnwrap(URL(string: "file:///etc/passwd"))

        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: same, isMainFrame: true, userTypedFileURL: typed)),
            .allow
        )
        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: otherPage, isMainFrame: true, userTypedFileURL: typed)),
            .denyFile
        )
        XCTAssertEqual(
            NavigationPolicy.decide(
                NavigationRequest(url: sibling, isMainFrame: false, userTypedFileURL: typed, currentPageURL: typed)
            ),
            .allow
        )
        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: outside, isMainFrame: false, userTypedFileURL: typed)),
            .denyFile
        )
        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: typed, isMainFrame: true)),
            .denyFile
        )
    }

    func testInternalPagesAreAllowedAndOtherWyvernHostsAreCancelled() throws {
        let bookmarks = try XCTUnwrap(URL(string: "wyvern://bookmarks"))
        let newTab = try XCTUnwrap(URL(string: "wyvern://newtab"))
        let other = try XCTUnwrap(URL(string: "wyvern://other"))
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: bookmarks, isMainFrame: true)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: newTab, isMainFrame: true)), .allow)
        XCTAssertEqual(NavigationPolicy.decide(NavigationRequest(url: other, isMainFrame: true)), .cancel)
    }

    func testMainFrameHTMLAllows() {
        let input = ResponseInput(
            isMainFrame: true,
            canShowMIMEType: true,
            mimeType: "text/html",
            statusCode: 200,
            contentDisposition: nil,
            userInitiated: true
        )
        XCTAssertEqual(
            NavigationPolicy.decideResponse(input),
            .allow,
            "main frame html with canShow true allows"
        )
    }

    func testSubframeOctetStreamNeverDownloads() {
        let input = ResponseInput(
            isMainFrame: false,
            canShowMIMEType: false,
            mimeType: "application/octet-stream",
            statusCode: 200,
            contentDisposition: nil,
            userInitiated: true
        )
        let decision = NavigationPolicy.decideResponse(input)
        XCTAssertEqual(decision, .cancelSilently, "subframe octet-stream never downloads")
        XCTAssertNotEqual(decision, .download)
        XCTAssertNotEqual(decision, .allow)
    }

    func testResponseRules() {
        struct Row {
            var name: String
            var input: ResponseInput
            var expected: ResponseDecision
        }
        let rows = [
            Row(
                name: "main attachment user downloads",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: "attachment", userInitiated: true),
                expected: .download
            ),
            Row(
                name: "main attachment with params downloads",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: "Attachment; filename=\"a.bin\"", userInitiated: true),
                expected: .download
            ),
            Row(
                name: "main attachment not user still downloads",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "application/pdf", statusCode: 200, contentDisposition: "attachment; filename=a.bin", userInitiated: false),
                expected: .download
            ),
            Row(
                name: "main undisplayable user downloads",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: nil, userInitiated: true),
                expected: .download
            ),
            Row(
                name: "main undisplayable not user still downloads",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: "inline", userInitiated: false),
                expected: .download
            ),
            Row(
                name: "main frame html with canShow true allows",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "text/html", statusCode: 200, contentDisposition: nil, userInitiated: false),
                expected: .allow
            ),
            Row(
                name: "main displayable inline allows",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "text/html", statusCode: 200, contentDisposition: "inline", userInitiated: true),
                expected: .allow
            ),
            Row(
                name: "subframe octet-stream never downloads",
                input: ResponseInput(isMainFrame: false, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: nil, userInitiated: true),
                expected: .cancelSilently
            ),
            Row(
                name: "subframe octet-stream without user still silent",
                input: ResponseInput(isMainFrame: false, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: nil, userInitiated: false),
                expected: .cancelSilently
            ),
            Row(
                name: "subframe attachment never notifies",
                input: ResponseInput(isMainFrame: false, canShowMIMEType: true, mimeType: "text/html", statusCode: 200, contentDisposition: "attachment; filename=x", userInitiated: true),
                expected: .cancelSilently
            ),
            Row(
                name: "subframe displayable allows",
                input: ResponseInput(isMainFrame: false, canShowMIMEType: true, mimeType: "text/html", statusCode: 200, contentDisposition: nil, userInitiated: false),
                expected: .allow
            ),
            Row(
                name: "status 204 allows even when undisplayable attachment",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 204, contentDisposition: "attachment", userInitiated: true),
                expected: .allow
            ),
            Row(
                name: "status 204 subframe allows",
                input: ResponseInput(isMainFrame: false, canShowMIMEType: false, mimeType: "application/octet-stream", statusCode: 204, contentDisposition: nil, userInitiated: false),
                expected: .allow
            ),
            Row(
                name: "status 205 allows",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: false, mimeType: "", statusCode: 205, contentDisposition: "attachment; filename=empty", userInitiated: false),
                expected: .allow
            ),
            Row(
                name: "status 200 html main allows",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "text/html", statusCode: 200, contentDisposition: "inline; filename=page.html", userInitiated: true),
                expected: .allow
            ),
            Row(
                name: "disposition padding still attachment",
                input: ResponseInput(isMainFrame: true, canShowMIMEType: true, mimeType: "application/octet-stream", statusCode: 200, contentDisposition: "  Attachment ; filename=a.bin", userInitiated: true),
                expected: .download
            )
        ]
        for row in rows {
            XCTAssertEqual(NavigationPolicy.decideResponse(row.input), row.expected, row.name)
        }
    }
}
