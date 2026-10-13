// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class DownloadNamingTests: XCTestCase {
    func testSanitizeStripsPathsAndLeadingDots() {
        XCTAssertEqual(DownloadNaming.sanitize("attach.bin"), "attach.bin")
        XCTAssertEqual(DownloadNaming.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(DownloadNaming.sanitize("folder/file.bin"), "file.bin")
        XCTAssertEqual(DownloadNaming.sanitize("C:\\temp\\a.bin"), "a.bin")
        XCTAssertEqual(DownloadNaming.sanitize(".hidden"), "hidden")
        XCTAssertEqual(DownloadNaming.sanitize("..."), "download")
        XCTAssertEqual(DownloadNaming.sanitize(""), "download")
        XCTAssertEqual(DownloadNaming.sanitize("   "), "download")
        XCTAssertEqual(DownloadNaming.sanitize("file:name.txt"), "file_name.txt")
    }

    func testUniqueNameInsertsNumberBeforeExtension() {
        XCTAssertEqual(DownloadNaming.uniqueName(desired: "a.bin", occupied: []), "a.bin")
        XCTAssertEqual(DownloadNaming.uniqueName(desired: "a.bin", occupied: ["a.bin"]), "a (1).bin")
        XCTAssertEqual(
            DownloadNaming.uniqueName(desired: "a.bin", occupied: ["a.bin", "a (1).bin"]),
            "a (2).bin"
        )
    }

    func testUniqueNameWithoutExtension() {
        XCTAssertEqual(DownloadNaming.uniqueName(desired: "file", occupied: ["file"]), "file (1)")
        XCTAssertEqual(
            DownloadNaming.uniqueName(desired: "file", occupied: ["file", "file (1)"]),
            "file (2)"
        )
    }

    func testTarGzKeepsCompoundExtension() {
        XCTAssertEqual(
            DownloadNaming.uniqueName(desired: "a.tar.gz", occupied: ["a.tar.gz"]),
            "a (1).tar.gz"
        )
        XCTAssertEqual(
            DownloadNaming.uniqueName(desired: "report.tar.bz2", occupied: ["report.tar.bz2"]),
            "report (1).tar.bz2"
        )
        let parts = DownloadNaming.splitStemExtension("archive.tar.gz")
        XCTAssertEqual(parts.stem, "archive")
        XCTAssertEqual(parts.ext, ".tar.gz")
    }

    func testAllocateSkipsOccupiedDownloadTemp() {
        let first = DownloadNaming.allocate(desired: "attach.bin", occupied: [])
        XCTAssertEqual(first.finalName, "attach.bin")
        XCTAssertEqual(first.tempName, "attach.bin.download")
        let second = DownloadNaming.allocate(
            desired: "attach.bin",
            occupied: ["attach.bin", "attach.bin.download"]
        )
        XCTAssertEqual(second.finalName, "attach (1).bin")
        XCTAssertEqual(second.tempName, "attach (1).bin.download")
        let onlyTemp = DownloadNaming.allocate(
            desired: "attach.bin",
            occupied: ["attach.bin.download"]
        )
        XCTAssertEqual(onlyTemp.finalName, "attach (1).bin")
    }

    /// The same URL downloaded three times, as DownloadManager.place sees the folder each time:
    /// finished files plus names reserved by transfers still in flight.
    func testRepeatedDownloadsOfOneURLAreNumbered() {
        var folder: Set<String> = []
        var names: [String] = []
        for _ in 0..<3 {
            let allocated = DownloadNaming.allocate(desired: "attach.bin", occupied: folder)
            names.append(allocated.finalName)
            folder.insert(allocated.finalName)
        }
        XCTAssertEqual(names, ["attach.bin", "attach (1).bin", "attach (2).bin"])

        // Second request starts while the first is still a `.download` temp file.
        let first = DownloadNaming.allocate(desired: "attach.bin", occupied: [])
        let inFlight: Set<String> = [first.finalName, first.tempName]
        let second = DownloadNaming.allocate(desired: "attach.bin", occupied: inFlight)
        XCTAssertEqual(second.finalName, "attach (1).bin")
        let third = DownloadNaming.allocate(
            desired: "attach.bin",
            occupied: inFlight.union([second.finalName, second.tempName])
        )
        XCTAssertEqual(third.finalName, "attach (2).bin")
        XCTAssertEqual(third.tempName, "attach (2).bin.download")
    }

    func testAllocateIsCaseInsensitive() {
        let result = DownloadNaming.allocate(desired: "Attach.bin", occupied: ["ATTACH.BIN"])
        XCTAssertEqual(result.finalName, "Attach (1).bin")
    }

    func testQuarantineAttributeFormat() {
        let uuid = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let value = QuarantineAttribute.value(unixTime: 0, uuid: uuid)
        XCTAssertEqual(value, "0083;0;\(AppInfo.shortName);11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(QuarantineAttribute.name, "com.apple.quarantine")
    }
}
