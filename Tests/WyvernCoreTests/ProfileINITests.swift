// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class ProfileINITests: XCTestCase {
    func testRelativeAndAbsolutePathsAndDefaultFlag() {
        let text = """
        [General]
        StartWithLastProfile=1

        [Profile0]
        Name=work
        IsRelative=1
        Path=Profiles/abcd.work

        [Profile1]
        Name=home
        IsRelative=0
        Path=/tmp/abs-profile
        Default=1
        """
        let file = ProfileINI.parseProfiles(text: text)
        XCTAssertEqual(file.profiles.count, 2)
        XCTAssertEqual(file.defaultProfile?.name, "home")
        let root = URL(fileURLWithPath: "/tmp/zen", isDirectory: true)
        let relative = file.profiles.first { $0.name == "work" }!
        XCTAssertEqual(
            ProfileINI.resolveDirectory(profile: relative, root: root)?.path,
            "/tmp/zen/Profiles/abcd.work"
        )
        let absolute = file.profiles.first { $0.name == "home" }!
        XCTAssertNil(ProfileINI.resolveDirectory(profile: absolute, root: root))
    }

    func testAbsolutePathInsideRootIsKept() {
        let text = """
        [Profile0]
        Name=inside
        IsRelative=0
        Path=/tmp/zen/Profiles/inside
        """
        let file = ProfileINI.parseProfiles(text: text)
        let root = URL(fileURLWithPath: "/tmp/zen", isDirectory: true)
        let profile = file.profiles[0]
        XCTAssertEqual(
            ProfileINI.resolveDirectory(profile: profile, root: root)?.path,
            "/tmp/zen/Profiles/inside"
        )
    }

    func testDotDotEscapeIsRejectedAndInsideStayIsKept() {
        let text = """
        [Profile0]
        Name=escape
        IsRelative=1
        Path=../outside

        [Profile1]
        Name=stay
        IsRelative=1
        Path=Profiles/sub/../abcd.work
        """
        let file = ProfileINI.parseProfiles(text: text)
        let root = URL(fileURLWithPath: "/tmp/zen", isDirectory: true)
        let escape = file.profiles.first { $0.name == "escape" }!
        let stay = file.profiles.first { $0.name == "stay" }!
        XCTAssertNil(ProfileINI.resolveDirectory(profile: escape, root: root))
        XCTAssertEqual(
            ProfileINI.resolveDirectory(profile: stay, root: root)?.path,
            "/tmp/zen/Profiles/abcd.work"
        )
        let sibling = INIProfile(name: "evil", path: "/tmp/zen-evil", isRelative: false, isDefault: false, section: "Profile2")
        XCTAssertNil(ProfileINI.resolveDirectory(profile: sibling, root: root))
    }

    func testSymlinkOutsideRootIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-ini-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profiles", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Profiles/link"),
            withDestinationURL: outside
        )
        let profile = INIProfile(
            name: "linked",
            path: "Profiles/link",
            isRelative: true,
            isDefault: false,
            section: "Profile0"
        )
        XCTAssertNil(ProfileINI.resolveDirectory(profile: profile, root: root))
    }

    func testInstallsIniDefaultWins() {
        let profiles = """
        [Profile0]
        Name=one
        IsRelative=1
        Path=Profiles/one
        Default=1

        [Profile1]
        Name=two
        IsRelative=1
        Path=Profiles/two
        """
        let installs = """
        [InstallABCDEF]
        Default=Profiles/two
        Locked=1
        """
        let file = ProfileINI.parseProfiles(text: profiles, installsText: installs)
        XCTAssertEqual(file.installsDefaultPath, "Profiles/two")
        XCTAssertEqual(file.defaultProfile?.name, "two")
    }

    func testMissingFilesYieldEmpty() {
        let file = ProfileINI.parseProfiles(text: "", installsText: nil)
        XCTAssertTrue(file.profiles.isEmpty)
        XCTAssertNil(file.defaultProfile)
        XCTAssertNil(ProfileINI.defaultPath(fromInstalls: ""))
    }
}
