// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class UpdateZipInspectorTests: XCTestCase {
    private let zipName = UpdateZipName(basename: "WyvernBrowser", version: "0.2.0", build: 3, fileName: "WyvernBrowser-0.2.0-b3.zip")

    private var allowed: Set<String> { zipName.memberNames }

    private func goodEntries() -> [TestZipEntry] {
        [
            TestZipEntry(zipName.dmgName, Data("dmg".utf8)),
            TestZipEntry(zipName.shaName, Data("sha".utf8)),
            TestZipEntry(zipName.sigName, Data("sig".utf8))
        ]
    }

    private func assertRejected(
        _ data: Data,
        _ expected: UpdatePackageError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try UpdateZipInspector.inspect(data, allowed: allowed), file: file, line: line) { error in
            XCTAssertEqual(error as? UpdatePackageError, expected, file: file, line: line)
        }
    }

    func testWellFormedZipPasses() throws {
        let entries = try UpdateZipInspector.inspect(TestZip.build(goodEntries()), allowed: allowed)
        XCTAssertEqual(Set(entries.map(\.name)), allowed)
    }

    func testParentTraversalRejected() {
        var entries = goodEntries()
        entries[2] = TestZipEntry("../" + zipName.sigName, Data("sig".utf8))
        assertRejected(TestZip.build(entries), .pathTraversal("../" + zipName.sigName))
    }

    func testAbsoluteAndNestedPathsRejected() {
        var absolute = goodEntries()
        absolute[0] = TestZipEntry("/tmp/" + zipName.dmgName, Data("dmg".utf8))
        assertRejected(TestZip.build(absolute), .pathTraversal("/tmp/" + zipName.dmgName))
        var nested = goodEntries()
        nested[0] = TestZipEntry("sub/" + zipName.dmgName, Data("dmg".utf8))
        assertRejected(TestZip.build(nested), .pathTraversal("sub/" + zipName.dmgName))
        var backslash = goodEntries()
        backslash[0] = TestZipEntry("..\\" + zipName.dmgName, Data("dmg".utf8))
        assertRejected(TestZip.build(backslash), .pathTraversal("..\\" + zipName.dmgName))
        var dotdot = goodEntries()
        dotdot.append(TestZipEntry("..", Data()))
        assertRejected(TestZip.build(dotdot), .pathTraversal(".."))
    }

    func testAppleDoubleFolderRejected() {
        var entries = goodEntries()
        entries.append(TestZipEntry("__MACOSX/._" + zipName.dmgName, Data("x".utf8)))
        assertRejected(TestZip.build(entries), .pathTraversal("__MACOSX/._" + zipName.dmgName))
    }

    func testSymlinkMemberRejected() {
        var entries = goodEntries()
        entries[0] = TestZipEntry(zipName.dmgName, Data("/Applications".utf8), unixMode: 0o120777)
        assertRejected(TestZip.build(entries), .symlinkRejected)
    }

    func testDirectoryMemberRejected() {
        var entries = goodEntries()
        entries[0] = TestZipEntry(zipName.dmgName, Data(), unixMode: 0o040755)
        assertRejected(TestZip.build(entries), .notRegularFile)
    }

    func testDuplicateExtraAndMissingRejected() {
        var duplicate = goodEntries()
        duplicate.append(TestZipEntry(zipName.dmgName, Data("again".utf8)))
        assertRejected(TestZip.build(duplicate), .duplicateEntry(zipName.dmgName))
        var extra = goodEntries()
        extra.append(TestZipEntry("extra.txt", Data("x".utf8)))
        assertRejected(TestZip.build(extra), .unexpectedEntry("extra.txt"))
        assertRejected(TestZip.build(Array(goodEntries().prefix(2))), .missingMember)
    }

    func testEncryptedEntryRejected() {
        var entries = goodEntries()
        entries[1] = TestZipEntry(zipName.shaName, Data("sha".utf8), flags: 0x0001)
        assertRejected(TestZip.build(entries), .unsupportedEntry(zipName.shaName))
    }

    /// An extractor that trusts local headers must see the same names as the central directory.
    func testLocalHeaderNameMismatchRejected() {
        var entries = goodEntries()
        entries[0] = TestZipEntry(zipName.dmgName, Data("dmg".utf8), localName: "../evil.dmg.xxxxxxxx")
        assertRejected(TestZip.build(entries), .zipMalformed)
    }

    func testPrependedDataAndTruncationRejected() {
        let good = TestZip.build(goodEntries())
        assertRejected(Data("JUNK".utf8) + good, .zipMalformed)
        assertRejected(good.prefix(good.count - 1), .zipMalformed)
        assertRejected(Data(), .zipMalformed)
        assertRejected(Data("not a zip at all, just text".utf8), .zipMalformed)
    }
}
