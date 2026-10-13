// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process timing marks. `emit` is a no-op unless `--app1-bench` enabled the flag.
public enum BenchMarks {
    public static let prefix = "BENCH_MARK"
    private static var enabled = false
    private static var onceNames: Set<String> = []

    public static var isEnabled: Bool { enabled }

    public static func enable() {
        enabled = true
    }

    public static func enableIfRequested(arguments: [String]) {
        if arguments.contains("--app1-bench") {
            enabled = true
        }
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds. Same domain in the app and the harness.
    public static func nowNanoseconds() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #else
        return 0
        #endif
    }

    public static func emit(_ name: String) {
        guard enabled else { return }
        write(name: name, ns: nowNanoseconds())
    }

    public static func emitOnce(_ name: String) {
        guard enabled else { return }
        if onceNames.contains(name) { return }
        onceNames.insert(name)
        write(name: name, ns: nowNanoseconds())
    }

    private static func write(name: String, ns: UInt64) {
        var line = "\(prefix) \(name) \(ns)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        #if canImport(Darwin)
        fflush(stdout)
        #endif
    }
}
