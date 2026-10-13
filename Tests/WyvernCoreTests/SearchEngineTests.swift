// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class SearchEngineTests: XCTestCase {
    func testBuiltInTemplatesAreTheDocumentedEndpoints() {
        XCTAssertEqual(SearchEngine.duckDuckGo.template, "https://duckduckgo.com/?q={query}")
        XCTAssertEqual(SearchEngine.google.template, "https://www.google.com/search?q={query}")
        XCTAssertEqual(SearchEngine.bing.template, "https://www.bing.com/search?q={query}")
        XCTAssertEqual(SearchEngine.kagi.template, "https://kagi.com/search?q={query}")
        XCTAssertEqual(SearchEngine.startpage.template, "https://www.startpage.com/do/search?q={query}")
        XCTAssertEqual(SearchEngine.builtIns.count, 5)
    }

    func testBuiltInTemplatesHaveOnlyTheQueryParameter() {
        for engine in SearchEngine.builtIns {
            let pieces = engine.template.split(separator: "?", omittingEmptySubsequences: false)
            XCTAssertEqual(pieces.count, 2, engine.id)
            XCTAssertEqual(String(pieces[1]), "q={query}", engine.id)
            XCTAssertTrue(engine.template.hasPrefix("https://"), engine.id)
        }
    }

    func testCustomRequiresHTTPSAndPlaceholder() {
        XCTAssertNotNil(SearchEngine.custom(template: " https://example.com/search?q={query} "))
        XCTAssertNil(SearchEngine.custom(template: "http://example.com/search?q={query}"))
        XCTAssertNil(SearchEngine.custom(template: "https://example.com/search"))
        XCTAssertNil(SearchEngine.custom(template: "javascript:alert({query})"))
        XCTAssertNil(SearchEngine.custom(template: "not a url {query}"))
    }

    func testInvalidCustomFallsBackToDuckDuckGo() {
        var settings = AppSettings.firstLaunch
        settings.searchEngineID = SearchEngine.customID
        settings.customSearchTemplate = "http://example.com/?q={query}"
        XCTAssertEqual(settings.resolvedSearchEngine().id, SearchEngine.duckDuckGo.id)

        settings.customSearchTemplate = "https://example.com/search?q={query}"
        XCTAssertEqual(settings.resolvedSearchEngine().id, SearchEngine.customID)
        XCTAssertEqual(
            settings.resolvedSearchEngine().url(forQuery: "qm")?.absoluteString,
            "https://example.com/search?q=qm"
        )
    }

    func testUnknownEngineIDFallsBackToDuckDuckGo() {
        var settings = AppSettings.firstLaunch
        settings.searchEngineID = "missing"
        XCTAssertEqual(settings.resolvedSearchEngine().id, SearchEngine.duckDuckGo.id)
    }

    func testSearchURLEncodesTheQuery() throws {
        let url = try XCTUnwrap(SearchEngine.duckDuckGo.url(forQuery: "a&b"))
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=a%26b")
    }
}
