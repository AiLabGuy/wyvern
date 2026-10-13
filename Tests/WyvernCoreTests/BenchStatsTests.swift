// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class BenchStatsTests: XCTestCase {
    func testOddCountMedianAndRange() {
        let summary = BenchStats.summarize(values: [9, 1, 5, 3, 7], errors: 0)
        XCTAssertEqual(summary.n, 5)
        XCTAssertEqual(summary.errors, 0)
        XCTAssertEqual(summary.median!, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.min!, 1, accuracy: 0.0001)
        XCTAssertEqual(summary.max!, 9, accuracy: 0.0001)
        XCTAssertEqual(summary.p90!, 8.2, accuracy: 0.0001)
    }

    func testEvenCountMedianIsMeanOfTheTwoCentralValues() {
        let summary = BenchStats.summarize(values: [4, 1, 3, 2], errors: 0)
        XCTAssertEqual(summary.n, 4)
        XCTAssertEqual(summary.median!, 2.5, accuracy: 0.0001)
        XCTAssertEqual(summary.min!, 1, accuracy: 0.0001)
        XCTAssertEqual(summary.max!, 4, accuracy: 0.0001)
    }

    func testP90LinearInterpolation() {
        let values = [1.0, 2, 3, 4, 5, 6, 7, 8, 9]
        let summary = BenchStats.summarize(values: values, errors: 0)
        XCTAssertEqual(summary.p90!, 8.2, accuracy: 0.0001)
        XCTAssertEqual(BenchStats.percentile(values, p: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(BenchStats.percentile(values, p: 100), 9, accuracy: 0.0001)
    }

    func testErrorsAreCountedAndExcludedFromPercentiles() {
        let summary = BenchStats.summarize(values: [10, 20, 30], errors: 2)
        XCTAssertEqual(summary.n, 3)
        XCTAssertEqual(summary.errors, 2)
        XCTAssertEqual(summary.median!, 20, accuracy: 0.0001)
        XCTAssertEqual(summary.min!, 10, accuracy: 0.0001)
        XCTAssertEqual(summary.max!, 30, accuracy: 0.0001)
    }

    func testAllErrorsYieldEmptyPercentiles() {
        let summary = BenchStats.summarize(values: [], errors: 4)
        XCTAssertEqual(summary.n, 0)
        XCTAssertEqual(summary.errors, 4)
        XCTAssertNil(summary.median)
        XCTAssertNil(summary.p90)
        XCTAssertNil(summary.min)
        XCTAssertNil(summary.max)
    }

    func testSingleSample() {
        let summary = BenchStats.summarize(values: [12.5], errors: 1)
        XCTAssertEqual(summary.n, 1)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertEqual(summary.median!, 12.5, accuracy: 0.0001)
        XCTAssertEqual(summary.p90!, 12.5, accuracy: 0.0001)
        XCTAssertEqual(summary.min!, 12.5, accuracy: 0.0001)
        XCTAssertEqual(summary.max!, 12.5, accuracy: 0.0001)
    }
}
