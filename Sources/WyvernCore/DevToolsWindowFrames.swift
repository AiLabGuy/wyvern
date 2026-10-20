// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Size rules and per-source memory for the popped-out DevTools window.
///
/// Default 900x640, minimum 640x420. The last frame is remembered per source tab, so tools for
/// two different pages can live in two different places. Frames are plain numbers so this stays
/// Foundation-only and testable.
public struct DevToolsWindowFrames: Equatable, Sendable {
    public struct Frame: Equatable, Codable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static let defaultWidth: Double = 900
    public static let defaultHeight: Double = 640
    public static let minimumWidth: Double = 640
    public static let minimumHeight: Double = 420
    /// Oldest entries are dropped past this many sources so the defaults value stays small.
    public static let capacity = 32

    private struct Entry: Equatable, Codable, Sendable {
        var source: String
        var frame: Frame
    }

    /// Most recent last.
    private var entries: [Entry]

    public init() {
        entries = []
    }

    public var count: Int { entries.count }

    /// Grows a frame to the minimum size. Origin is kept. Non-finite frames are rejected.
    public static func clamped(_ frame: Frame) -> Frame? {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        return Frame(
            x: frame.x,
            y: frame.y,
            width: max(frame.width, minimumWidth),
            height: max(frame.height, minimumHeight)
        )
    }

    public func frame(for source: UUID) -> Frame? {
        entries.last(where: { $0.source == source.uuidString })?.frame
    }

    public mutating func remember(_ frame: Frame, for source: UUID) {
        guard let frame = Self.clamped(frame) else { return }
        entries.removeAll { $0.source == source.uuidString }
        entries.append(Entry(source: source.uuidString, frame: frame))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public mutating func forget(_ source: UUID) {
        entries.removeAll { $0.source == source.uuidString }
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// Unreadable data gives an empty memory. Stored frames are clamped again on read.
    public static func decode(_ data: Data?) -> DevToolsWindowFrames {
        var result = DevToolsWindowFrames()
        guard let data, let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return result }
        for entry in stored.suffix(capacity) {
            guard let id = UUID(uuidString: entry.source) else { continue }
            result.remember(entry.frame, for: id)
        }
        return result
    }
}
