// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class PrivateFileTests: XCTestCase {
    func testDirectoryAndFileAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-private-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("state.json")
        try PrivateFile.write(Data("secret".utf8), to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(permission(root), 0o700)
        XCTAssertEqual(permission(file), 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, "secret")
    }

    private func permission(_ url: URL) -> Int {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { return -1 }
        return Int(mode_t(info.st_mode) & 0o777)
    }
}
