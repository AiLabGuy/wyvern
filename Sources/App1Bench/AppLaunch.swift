// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import Foundation
import App1Core

final class AppLaunch {
    let process: Process
    let collector: MarkCollector
    let dataDir: String
    let runNanoseconds: UInt64
    var pid: pid_t { process.processIdentifier }

    private let pipe: Pipe
    private let errPath: String

    private init(process: Process, collector: MarkCollector, dataDir: String, runNanoseconds: UInt64, pipe: Pipe, errPath: String) {
        self.process = process
        self.collector = collector
        self.dataDir = dataDir
        self.runNanoseconds = runNanoseconds
        self.pipe = pipe
        self.errPath = errPath
    }

    static func start(binary: String, url: String?) throws -> AppLaunch {
        let dataDir = "/tmp/app1-bench-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var arguments = [
            "--app1-data-dir", dataDir,
            "--app1-skip-engine-chooser",
            "--app1-window-size", "1360x830",
            "--app1-appearance", "light",
            "--app1-bench"
        ]
        if let url, !url.isEmpty {
            arguments.append(contentsOf: ["--app1-open-url", url])
        }
        let pipe = Pipe()
        let collector = MarkCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.ingest(data)
        }
        let errPath = dataDir + "/app-stderr.log"
        FileManager.default.createFile(atPath: errPath, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: errPath) ?? FileHandle.nullDevice
        let runNs = BenchMarks.nowNanoseconds()
        try process.run()
        return AppLaunch(
            process: process,
            collector: collector,
            dataDir: dataDir,
            runNanoseconds: runNs,
            pipe: pipe,
            errPath: errPath
        )
    }

    func activate() {
        if let running = NSRunningApplication(processIdentifier: process.processIdentifier) {
            _ = running.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try? FileManager.default.removeItem(atPath: dataDir)
    }

    var stderrTail: String {
        guard let data = FileManager.default.contents(atPath: errPath),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.split(separator: "\n").suffix(8).joined(separator: " | ")
    }
}

enum BenchPaths {
    static func executable(inApp appPath: String) -> String? {
        let folder = (appPath as NSString).appendingPathComponent("Contents/MacOS")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return items
            .map { (folder as NSString).appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum BenchClock {
    static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        if end < start { return 0 }
        return Double(end - start) / 1_000_000.0
    }
}

enum HostInfo {
    static func sysctl(_ name: String) -> String {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    static func loadAverage() -> String {
        command("/usr/sbin/sysctl", ["vm.loadavg"])
    }

    static func command(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return ""
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
