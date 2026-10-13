// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// How long a login-shell lookup and a Spotlight lookup wait before they are killed.
public enum CommandPathTiming {
    public static let timeout: TimeInterval = 2
}

/// Runs `$SHELL -lic 'command -v NAME'` and returns that process's stdout.
/// Nil means the process failed, exited non-zero, or was killed at the timeout.
public protocol CommandShellRunning: Sendable {
    func commandV(_ name: String, timeout: TimeInterval) -> String?
}

/// File checks the resolver uses after the login shell. Implementations must not treat a directory as executable.
public protocol CommandPathFileSystem: Sendable {
    func homeDirectory() -> String
    func isExecutableFile(at path: String) -> Bool
    /// Executable files directly inside `directory`, directories omitted. Missing directories return an empty list.
    func executableFiles(in directory: String) -> [String]
    /// Paths from `mdfind` for `kMDItemFSName == NAME`, in the order the tool printed them.
    func spotlightPaths(named name: String) -> [String]
}

/// What to show when a bookmark command's first word is a bare name.
public enum CommandPathResolution: Equatable, Sendable {
    case unchanged
    case suggested(name: String, path: String)
    case notFound(name: String)
}

/// Shell argv and the Spotlight query. The name is quoted so it cannot change the command.
public enum CommandInvocation {
    public static func loginShellArguments(name: String) -> [String] {
        ["-lic", "command -v \(singleQuoted(name))"]
    }

    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// `kMDItemFSName == NAME`, with the name in quotes so spaces stay one token.
    public static func spotlightQuery(name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "kMDItemFSName == \"\(escaped)\""
    }
}

/// First word of a bookmark command. A bare name has no slash and no line break.
public enum CommandWords {
    public static func bareName(in command: String) -> String? {
        guard let word = first(in: command) else { return nil }
        let token = word.token
        if token.isEmpty || token.contains("/") { return nil }
        if token.contains("\n") || token.contains("\r") || token.contains("\0") { return nil }
        return token
    }

    /// Replaces only the first word. The rest of the command, including its spacing, stays.
    public static func replacingFirstWord(in command: String, with replacement: String) -> String {
        guard let word = first(in: command) else { return command }
        return word.leading + replacement + word.rest
    }

    static func first(in command: String) -> (leading: String, token: String, rest: String)? {
        var index = command.startIndex
        while index < command.endIndex, command[index].isWhitespace {
            index = command.index(after: index)
        }
        if index == command.endIndex { return nil }
        let leading = String(command[..<index])
        let opener = command[index]
        if opener == "'" || opener == "\"" {
            let contentStart = command.index(after: index)
            if let close = command[contentStart...].firstIndex(of: opener) {
                let token = String(command[contentStart..<close])
                let after = command.index(after: close)
                return (leading, token, String(command[after...]))
            }
            return (leading, String(command[contentStart...]), "")
        }
        var end = index
        while end < command.endIndex, !command[end].isWhitespace {
            end = command.index(after: end)
        }
        return (leading, String(command[index..<end]), String(command[end...]))
    }
}

/// Picks an absolute path out of `command -v` stdout. Banners and a trailing prompt are ignored.
enum CommandVOutput {
    static func absolutePath(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for line in lines.reversed() {
            if line.hasPrefix("/"), !line.contains("\0") {
                return line
            }
        }
        return nil
    }
}

/// Resolves a bare command name: login-shell PATH, then common directories, then app bundles, then Spotlight.
public struct CommandPathResolver<Shell: CommandShellRunning, Files: CommandPathFileSystem>: Sendable {
    public var shell: Shell
    public var files: Files
    public var timeout: TimeInterval

    public init(shell: Shell, files: Files, timeout: TimeInterval = CommandPathTiming.timeout) {
        self.shell = shell
        self.files = files
        self.timeout = timeout
    }

    public func resolve(_ command: String) -> CommandPathResolution {
        guard let name = CommandWords.bareName(in: command) else { return .unchanged }
        if let path = lookup(name) {
            return .suggested(name: name, path: path)
        }
        return .notFound(name: name)
    }

    private func lookup(_ name: String) -> String? {
        if let output = shell.commandV(name, timeout: timeout), let path = CommandVOutput.absolutePath(in: output) {
            return path
        }
        for candidate in commonCandidates(name) where files.isExecutableFile(at: candidate) {
            return candidate
        }
        for directory in applicationDirectories(name) {
            if let path = preferredExecutable(named: name, in: directory) {
                return path
            }
        }
        for match in files.spotlightPaths(named: name) {
            if files.isExecutableFile(at: match) {
                return match
            }
            if let bundle = applicationBundleDirectory(match), let path = preferredExecutable(named: name, in: bundle) {
                return path
            }
        }
        return nil
    }

    private func commonCandidates(_ name: String) -> [String] {
        var paths: [String] = []
        let home = normalizedHome()
        if !home.isEmpty {
            paths.append("\(home)/.\(name)/bin/\(name)")
            paths.append("\(home)/.local/bin/\(name)")
            paths.append("\(home)/bin/\(name)")
        }
        paths.append("/opt/homebrew/bin/\(name)")
        paths.append("/usr/local/bin/\(name)")
        return paths
    }

    private func applicationDirectories(_ name: String) -> [String] {
        var roots = ["/Applications"]
        let home = normalizedHome()
        if !home.isEmpty {
            roots.append("\(home)/Applications")
        }
        return roots.map { "\($0)/\(name).app/Contents/MacOS" }
    }

    /// Exact file name wins. Otherwise the first non-dot executable in sorted order.
    private func preferredExecutable(named name: String, in directory: String) -> String? {
        let visible = files.executableFiles(in: directory).filter { !lastComponent($0).hasPrefix(".") }
        if let match = visible.first(where: { lastComponent($0) == name }) {
            return match
        }
        return visible.min { lastComponent($0) < lastComponent($1) }
    }

    private func applicationBundleDirectory(_ path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard trimmed.hasSuffix(".app") else { return nil }
        return trimmed + "/Contents/MacOS"
    }

    private func normalizedHome() -> String {
        var home = files.homeDirectory()
        while home.count > 1, home.hasSuffix("/") {
            home.removeLast()
        }
        if home == "/" { return "" }
        return home
    }

    private func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// `$SHELL` from the environment. A relative or broken value falls back to `/bin/zsh`.
public struct LoginShellCommandRunner: CommandShellRunning, Sendable {
    public var shellPath: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let raw = environment["SHELL"] ?? ""
        if raw.hasPrefix("/"), !raw.contains("\n"), !raw.contains("\r"), !raw.contains("\0") {
            shellPath = raw
        } else {
            shellPath = "/bin/zsh"
        }
    }

    /// Call off the main thread. The process is killed if it is still running after `timeout`.
    public func commandV(_ name: String, timeout: TimeInterval) -> String? {
        TimedProcess.stdout(
            executable: shellPath,
            arguments: CommandInvocation.loginShellArguments(name: name),
            timeout: timeout
        )
    }
}

public struct LiveCommandPathFileSystem: CommandPathFileSystem, Sendable {
    public var spotlightTimeout: TimeInterval

    public init(spotlightTimeout: TimeInterval = CommandPathTiming.timeout) {
        self.spotlightTimeout = spotlightTimeout
    }

    public func homeDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    public func isExecutableFile(at path: String) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func executableFiles(in directory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = (directory as NSString).appendingPathComponent(name)
            return isExecutableFile(at: path) ? path : nil
        }
    }

    public func spotlightPaths(named name: String) -> [String] {
        guard let output = TimedProcess.stdout(
            executable: "/usr/bin/mdfind",
            arguments: [CommandInvocation.spotlightQuery(name: name)],
            timeout: spotlightTimeout
        ) else {
            return []
        }
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("/") }
    }
}

/// One-shot process with a timeout. Callers run this off the main thread.
enum TimedProcess {
    static func stdout(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchGroup()
        finished.enter()
        let gate = LeaveOnce()
        process.terminationHandler = { _ in
            if gate.claim() {
                finished.leave()
            }
        }
        do {
            try process.run()
        } catch {
            if gate.claim() {
                finished.leave()
            }
            return nil
        }
        let box = OutputBox()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.3)
            }
            _ = reader.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: box.data, encoding: .utf8)
    }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

/// Makes the process-exit and launch-failure paths leave a DispatchGroup only once.
private final class LeaveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
