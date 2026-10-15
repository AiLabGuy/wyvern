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

    func testShellOptionURLsAreNotConfirmed() throws {
        let blocked = [
            "ssh://-oProxyCommand=calc/example.com",
            "ssh://%2DoProxyCommand%3Dcalc@example.com",
            "ssh://%20-oProxyCommand@example.com",
            "ssh://example.com/?Proxy%43ommand=calc",
            "ssh://example.com#ProxyCommand",
            "telnet://-n/example.com",
            "ssh:///path",
            "ssh://example.com/%0A-oBatchMode=yes",
            "sftp://example.com/-oBatchMode=yes",
            "scp://user@-evil.example/file",
            "rlogin://example.com/?LocalCommand=id",
            "rsh://example.com/?PermitLocalCommand=yes"
        ]
        for raw in blocked {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertFalse(ExternalLaunchPolicy.allowsConfirmation(url), raw)
            XCTAssertEqual(
                NavigationPolicy.decide(NavigationRequest(url: url, isMainFrame: true)),
                .cancel,
                raw
            )
        }
        let benign = try XCTUnwrap(URL(string: "ssh://example.com"))
        XCTAssertTrue(ExternalLaunchPolicy.allowsConfirmation(benign))
        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: benign, isMainFrame: true)),
            .confirmExternal
        )
        let mail = try XCTUnwrap(URL(string: "mailto:person@example.com"))
        XCTAssertEqual(
            NavigationPolicy.decide(NavigationRequest(url: mail, isMainFrame: true)),
            .confirmExternal
        )
    }

    func testExternalPromptTextStripsBidiAndCapsLength() throws {
        let spoof = try XCTUnwrap(URL(string: "https://evil.example/\u{202E}moc.elpmaxe"))
        let shown = ExternalLaunchPolicy.promptText(for: spoof)
        XCTAssertFalse(shown.unicodeScalars.contains { $0.value == 0x202E })
        let long = "https://example.com/" + String(repeating: "a", count: 400)
        let huge = try XCTUnwrap(URL(string: long))
        let capped = ExternalLaunchPolicy.promptText(for: huge)
        XCTAssertLessThanOrEqual(capped.count, 181)
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    func testExternalPromptGateStopsAfterThree() {
        let start = Date(timeIntervalSince1970: 1_000)
        var recent: [Date] = []
        for _ in 0..<ExternalPromptGate.maxPerWindow {
            let step = ExternalPromptGate.allow(recent: recent, now: start)
            XCTAssertTrue(step.allow)
            recent = step.retained
        }
        let blocked = ExternalPromptGate.allow(recent: recent, now: start.addingTimeInterval(1))
        XCTAssertFalse(blocked.allow)
        XCTAssertEqual(blocked.retained.count, ExternalPromptGate.maxPerWindow)
        let later = ExternalPromptGate.allow(
            recent: recent,
            now: start.addingTimeInterval(ExternalPromptGate.windowSeconds + 1)
        )
        XCTAssertTrue(later.allow)
    }

    func testInspectorOpensOnlyWebURLs() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com/a"))
        let http = try XCTUnwrap(URL(string: "http://example.com/a"))
        XCTAssertTrue(ExternalLaunchPolicy.canOpenFromInspector(https))
        XCTAssertTrue(ExternalLaunchPolicy.canOpenFromInspector(http))
        for raw in ["ssh://example.com", "file:///etc/passwd", "javascript:alert(1)", "customapp://open"] {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertFalse(ExternalLaunchPolicy.canOpenFromInspector(url), raw)
        }
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

    func testFileGrantDoesNotSurviveAWebsite() throws {
        let typed = try XCTUnwrap(URL(string: "file:///tmp/site/index.html"))
        let sibling = try XCTUnwrap(URL(string: "file:///tmp/site/secret.txt"))
        let web = try XCTUnwrap(URL(string: "https://evil.example/"))
        let about = try XCTUnwrap(URL(string: "about:blank"))
        XCTAssertEqual(
            NavigationPolicy.decide(
                NavigationRequest(url: sibling, isMainFrame: false, userTypedFileURL: typed, currentPageURL: web)
            ),
            .denyFile
        )
        XCTAssertEqual(
            NavigationPolicy.decide(
                NavigationRequest(url: typed, isMainFrame: true, userTypedFileURL: typed, currentPageURL: web)
            ),
            .denyFile
        )
        XCTAssertEqual(
            NavigationPolicy.decide(
                NavigationRequest(url: sibling, isMainFrame: false, userTypedFileURL: typed, currentPageURL: about)
            ),
            .denyFile
        )
        XCTAssertEqual(
            NavigationPolicy.decide(
                NavigationRequest(url: typed, isMainFrame: true, userTypedFileURL: typed, currentPageURL: about)
            ),
            .allow
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
