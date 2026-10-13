// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import App1Core

final class CommandPathResolverTests: XCTestCase {
    func testLoginShellArgumentsQuoteTheName() {
        XCTAssertEqual(CommandPathTiming.timeout, 2)
        XCTAssertEqual(
            CommandInvocation.loginShellArguments(name: "htop"),
            ["-lic", "command -v 'htop'"]
        )
        XCTAssertEqual(
            CommandInvocation.loginShellArguments(name: "foo'bar"),
            ["-lic", "command -v 'foo'\"'\"'bar'"]
        )
        XCTAssertEqual(
            CommandInvocation.loginShellArguments(name: "htop;rm"),
            ["-lic", "command -v 'htop;rm'"]
        )
    }

    func testSpotlightQueryQuotesTheName() {
        XCTAssertEqual(CommandInvocation.spotlightQuery(name: "htop"), "kMDItemFSName == \"htop\"")
        XCTAssertEqual(CommandInvocation.spotlightQuery(name: "a\"b"), "kMDItemFSName == \"a\\\"b\"")
    }

    func testShellPathUsesAbsoluteEnvironmentValue() {
        XCTAssertEqual(LoginShellCommandRunner(environment: ["SHELL": "/bin/bash"]).shellPath, "/bin/bash")
        XCTAssertEqual(LoginShellCommandRunner(environment: ["SHELL": "bash"]).shellPath, "/bin/zsh")
        XCTAssertEqual(LoginShellCommandRunner(environment: ["SHELL": "/bin/zsh\n"]).shellPath, "/bin/zsh")
        XCTAssertEqual(LoginShellCommandRunner(environment: [:]).shellPath, "/bin/zsh")
    }

    func testCommandVOutputSkipsBannersAndPrompts() {
        XCTAssertEqual(
            CommandVOutput.absolutePath(in: "welcome\n/opt/homebrew/bin/htop\nme% "),
            "/opt/homebrew/bin/htop"
        )
        XCTAssertEqual(CommandVOutput.absolutePath(in: "  /usr/bin/htop\n"), "/usr/bin/htop")
        XCTAssertNil(CommandVOutput.absolutePath(in: "htop\n"))
        XCTAssertNil(CommandVOutput.absolutePath(in: "not a path"))
    }

    func testSlashAndEmptyCommandsSkipTheShell() {
        let shell = FakeShell()
        shell.output = "/usr/bin/htop"
        let files = FakeCommandFiles()
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("/bin/echo hi"), .unchanged)
        XCTAssertEqual(resolver.resolve("  './script' arg"), .unchanged)
        XCTAssertEqual(resolver.resolve(""), .unchanged)
        XCTAssertEqual(resolver.resolve("   "), .unchanged)
        XCTAssertEqual(resolver.resolve("\"htop\n\" -d"), .unchanged)
        XCTAssertTrue(shell.calls.isEmpty)
        XCTAssertTrue(files.checked.isEmpty)
        XCTAssertTrue(files.spotlightNames.isEmpty)
    }

    func testShellPathWinsAndReceivesTheTimeout() {
        let shell = FakeShell()
        shell.output = "welcome\n/usr/bin/htop\n"
        let files = FakeCommandFiles()
        files.executable = ["/opt/homebrew/bin/htop"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("htop -d 5"), .suggested(name: "htop", path: "/usr/bin/htop"))
        XCTAssertEqual(shell.calls.map(\.name), ["htop"])
        XCTAssertEqual(shell.calls.map(\.timeout), [CommandPathTiming.timeout])
        XCTAssertTrue(files.checked.isEmpty)
        XCTAssertTrue(files.listedDirectories.isEmpty)
        XCTAssertTrue(files.spotlightNames.isEmpty)
    }

    func testRelativeShellOutputFallsThroughToCommonDirectories() {
        let shell = FakeShell()
        shell.output = "htop"
        let files = FakeCommandFiles()
        files.executable = ["/usr/local/bin/htop"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("  htop"), .suggested(name: "htop", path: "/usr/local/bin/htop"))
        XCTAssertEqual(files.checked, [
            "/Users/me/.htop/bin/htop",
            "/Users/me/.local/bin/htop",
            "/Users/me/bin/htop",
            "/opt/homebrew/bin/htop",
            "/usr/local/bin/htop"
        ])
        XCTAssertTrue(files.listedDirectories.isEmpty)
    }

    func testCommonDirectoryOrderStopsAtTheFirstExecutable() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        files.home = "/Users/me/"
        files.executable = ["/Users/me/.local/bin/cargo"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("cargo build"), .suggested(name: "cargo", path: "/Users/me/.local/bin/cargo"))
        XCTAssertEqual(files.checked, [
            "/Users/me/.cargo/bin/cargo",
            "/Users/me/.local/bin/cargo"
        ])
        XCTAssertTrue(files.spotlightNames.isEmpty)
    }

    func testEmptyHomeSkipsTildePaths() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        files.home = "/"
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("tool"), .notFound(name: "tool"))
        XCTAssertEqual(files.checked, [
            "/opt/homebrew/bin/tool",
            "/usr/local/bin/tool"
        ])
        XCTAssertEqual(files.listedDirectories, ["/Applications/tool.app/Contents/MacOS"])
        XCTAssertEqual(files.spotlightNames, ["tool"])
    }

    func testApplicationBundlePrefersTheNamedExecutable() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        let macOS = "/Applications/Htop.app/Contents/MacOS"
        files.listed[macOS] = [
            "\(macOS)/helper",
            "\(macOS)/.hidden",
            "\(macOS)/Htop"
        ]
        files.listed["/Users/me/Applications/Htop.app/Contents/MacOS"] = ["\(macOS)/other"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("Htop"), .suggested(name: "Htop", path: "\(macOS)/Htop"))
        XCTAssertEqual(files.listedDirectories, [macOS])
        XCTAssertTrue(files.spotlightNames.isEmpty)
    }

    func testApplicationBundleUsesSortedFallbackThenHomeApplications() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        let system = "/Applications/Tool.app/Contents/MacOS"
        let home = "/Users/me/Applications/Tool.app/Contents/MacOS"
        files.listed[system] = ["\(system)/.hidden"]
        files.listed[home] = ["\(home)/zeta", "\(home)/alpha"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("Tool"), .suggested(name: "Tool", path: "\(home)/alpha"))
        XCTAssertEqual(files.listedDirectories, [system, home])
        XCTAssertTrue(files.spotlightNames.isEmpty)
    }

    func testSpotlightRunsAfterBundlesAndSkipsNonExecutables() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        files.spotlight = ["/Custom/readme", "/Custom/htop"]
        files.executable = ["/Custom/htop"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("\"htop\" -d"), .suggested(name: "htop", path: "/Custom/htop"))
        XCTAssertEqual(files.spotlightNames, ["htop"])
        XCTAssertTrue(files.checked.contains("/Custom/readme"))
        XCTAssertTrue(files.checked.contains("/Custom/htop"))
    }

    func testSpotlightAppBundle() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        files.spotlight = ["/Custom/Htop.app"]
        files.listed["/Custom/Htop.app/Contents/MacOS"] = ["/Custom/Htop.app/Contents/MacOS/Htop"]
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("Htop"), .suggested(name: "Htop", path: "/Custom/Htop.app/Contents/MacOS/Htop"))
    }

    func testNotFoundWhenEveryStepMisses() {
        let shell = FakeShell()
        let files = FakeCommandFiles()
        let resolver = CommandPathResolver(shell: shell, files: files)
        XCTAssertEqual(resolver.resolve("missing"), .notFound(name: "missing"))
        XCTAssertEqual(shell.calls.map(\.name), ["missing"])
        XCTAssertEqual(files.spotlightNames, ["missing"])
    }

    func testReplacingFirstWordKeepsTheRemainder() {
        XCTAssertEqual(
            CommandWords.replacingFirstWord(in: "htop -d 5", with: "/usr/bin/htop"),
            "/usr/bin/htop -d 5"
        )
        XCTAssertEqual(
            CommandWords.replacingFirstWord(in: "  htop   -d", with: "/usr/bin/htop"),
            "  /usr/bin/htop   -d"
        )
        XCTAssertEqual(
            CommandWords.replacingFirstWord(in: "\"my tool\" --flag", with: "/opt/my tool"),
            "/opt/my tool --flag"
        )
        XCTAssertEqual(CommandWords.bareName(in: "echo hi"), "echo")
        XCTAssertNil(CommandWords.bareName(in: "/bin/echo hi"))
    }

    func testLiveFileSystemIgnoresDirectoriesDotfilesAndNonExecutables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("tool")
        let note = root.appendingPathComponent("note")
        let hidden = root.appendingPathComponent(".hidden")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data("echo".utf8))
        FileManager.default.createFile(atPath: note.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: hidden.path, contents: Data("x".utf8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: note.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path)
        let files = LiveCommandPathFileSystem()
        XCTAssertTrue(files.isExecutableFile(at: tool.path))
        XCTAssertFalse(files.isExecutableFile(at: note.path))
        XCTAssertFalse(files.isExecutableFile(at: folder.path))
        XCTAssertFalse(files.isExecutableFile(at: root.path))
        XCTAssertTrue(files.isExecutableFile(at: hidden.path))
        XCTAssertEqual(files.executableFiles(in: root.path), [tool.path])
        XCTAssertTrue(files.homeDirectory().hasPrefix("/"))
    }
}

private final class FakeShell: CommandShellRunning, @unchecked Sendable {
    var output: String?
    var calls: [(name: String, timeout: TimeInterval)] = []

    func commandV(_ name: String, timeout: TimeInterval) -> String? {
        calls.append((name, timeout))
        return output
    }
}

private final class FakeCommandFiles: CommandPathFileSystem, @unchecked Sendable {
    var home = "/Users/me"
    var executable: Set<String> = []
    var listed: [String: [String]] = [:]
    var spotlight: [String] = []
    var checked: [String] = []
    var listedDirectories: [String] = []
    var spotlightNames: [String] = []

    func homeDirectory() -> String { home }

    func isExecutableFile(at path: String) -> Bool {
        checked.append(path)
        return executable.contains(path)
    }

    func executableFiles(in directory: String) -> [String] {
        listedDirectories.append(directory)
        return listed[directory] ?? []
    }

    func spotlightPaths(named name: String) -> [String] {
        spotlightNames.append(name)
        return spotlight
    }
}
