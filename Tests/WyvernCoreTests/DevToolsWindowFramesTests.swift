// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class DevToolsWindowFramesTests: XCTestCase {
    typealias Frame = DevToolsWindowFrames.Frame

    func testDefaultAndMinimumSizes() {
        XCTAssertEqual(DevToolsWindowFrames.defaultWidth, 900)
        XCTAssertEqual(DevToolsWindowFrames.defaultHeight, 640)
        XCTAssertEqual(DevToolsWindowFrames.minimumWidth, 640)
        XCTAssertEqual(DevToolsWindowFrames.minimumHeight, 420)
        XCTAssertEqual(DevToolsWindowFrames.maximumWidth, 8192)
        XCTAssertEqual(DevToolsWindowFrames.maximumHeight, 8192)
    }

    func testFramesAreRememberedPerSource() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        let b = UUID()
        frames.remember(Frame(x: 10, y: 20, width: 1000, height: 700), for: a)
        frames.remember(Frame(x: 300, y: 40, width: 800, height: 500), for: b)
        XCTAssertEqual(frames.frame(for: a), Frame(x: 10, y: 20, width: 1000, height: 700))
        XCTAssertEqual(frames.frame(for: b), Frame(x: 300, y: 40, width: 800, height: 500))
        XCTAssertNil(frames.frame(for: UUID()))
    }

    func testLatestFrameWinsForOneSource() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: 0, y: 0, width: 900, height: 640), for: a)
        frames.remember(Frame(x: 5, y: 6, width: 950, height: 650), for: a)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.frame(for: a), Frame(x: 5, y: 6, width: 950, height: 650))
    }

    func testSmallFramesAreClampedToTheMinimum() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: 1, y: 2, width: 300, height: 100), for: a)
        XCTAssertEqual(frames.frame(for: a), Frame(x: 1, y: 2, width: 640, height: 420))
    }

    func testNonFiniteFramesAreIgnored() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: .nan, y: 0, width: 900, height: 640), for: a)
        XCTAssertNil(frames.frame(for: a))
        frames.remember(Frame(x: 0, y: 0, width: .infinity, height: 640), for: a)
        XCTAssertNil(frames.frame(for: a))
    }

    func testHugeFramesAreClampedToTheMaximum() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: 1, y: 2, width: 1_000_000, height: 1_000_000), for: a)
        XCTAssertEqual(
            frames.frame(for: a),
            Frame(x: 1, y: 2, width: DevToolsWindowFrames.maximumWidth, height: DevToolsWindowFrames.maximumHeight)
        )
        let decoded = DevToolsWindowFrames.decode(
            Data(#"[{"source":"\#(a.uuidString)","frame":{"x":0,"y":0,"width":1e20,"height":1e20}}]"#.utf8)
        )
        XCTAssertEqual(decoded.frame(for: a)?.width, DevToolsWindowFrames.maximumWidth)
        XCTAssertEqual(decoded.frame(for: a)?.height, DevToolsWindowFrames.maximumHeight)
    }

    func testCapacityDropsTheOldest() {
        var frames = DevToolsWindowFrames()
        let first = UUID()
        frames.remember(Frame(x: 0, y: 0, width: 900, height: 640), for: first)
        for _ in 0..<DevToolsWindowFrames.capacity {
            frames.remember(Frame(x: 0, y: 0, width: 900, height: 640), for: UUID())
        }
        XCTAssertEqual(frames.count, DevToolsWindowFrames.capacity)
        XCTAssertNil(frames.frame(for: first))
    }

    func testRoundTripAndCorruptData() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: 12, y: 34, width: 900, height: 640), for: a)
        let decoded = DevToolsWindowFrames.decode(frames.encoded())
        XCTAssertEqual(decoded.frame(for: a), Frame(x: 12, y: 34, width: 900, height: 640))
        XCTAssertEqual(DevToolsWindowFrames.decode(Data("nope".utf8)).count, 0)
        XCTAssertEqual(DevToolsWindowFrames.decode(nil).count, 0)
    }

    func testForget() {
        var frames = DevToolsWindowFrames()
        let a = UUID()
        frames.remember(Frame(x: 0, y: 0, width: 900, height: 640), for: a)
        frames.forget(a)
        XCTAssertNil(frames.frame(for: a))
    }
}
