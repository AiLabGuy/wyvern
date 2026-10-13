// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import App1Core

/// Memory sample for the app process plus WebKit XPC children.
///
/// Method: `proc_pid_rusage(pid, RUSAGE_INFO_V4)` reads `ri_phys_footprint`,
/// the same physical-footprint counter `task_info(TASK_VM_INFO)` exposes as
/// `phys_footprint`. The harness does not call `task_for_pid` (that needs a
/// privileged task port).
///
/// WebKit WebContent / Networking / GPU XPC services are launched by launchd
/// (`ppid` 1), so a parent-pid check misses them. Helpers are:
/// - any pid whose parent or responsible pid is the app, and whose name looks
///   like WebKit; or
/// - any **new** pid (not in the pre-launch snapshot) owned by the same uid
///   whose `proc_name` or `proc_pidpath` contains `com.apple.WebKit`.
struct MemorySample {
    var appBytes: UInt64
    var webContentBytes: UInt64
    var networkingBytes: UInt64
    var gpuBytes: UInt64
    var childrenBytes: UInt64
    var childCount: Int
    var totalBytes: UInt64 { appBytes + childrenBytes }
}

enum MemorySampler {
    static func snapshotPids() -> Set<pid_t> {
        Set(listPids())
    }

    static func sample(appPid: pid_t, baseline: Set<pid_t> = []) -> MemorySample? {
        guard let appBytes = physFootprint(pid: appPid) else { return nil }
        let uid = getuid()
        var webContent: UInt64 = 0
        var networking: UInt64 = 0
        var gpu: UInt64 = 0
        var children: UInt64 = 0
        var count = 0
        for pid in listPids() {
            guard pid != appPid, pid > 0 else { continue }
            guard isAppHelper(pid: pid, appPid: appPid, uid: uid, baseline: baseline) else { continue }
            guard let bytes = physFootprint(pid: pid) else { continue }
            children += bytes
            count += 1
            switch kind(pid: pid) {
            case .webContent: webContent += bytes
            case .networking: networking += bytes
            case .gpu: gpu += bytes
            case nil: break
            }
        }
        return MemorySample(
            appBytes: appBytes,
            webContentBytes: webContent,
            networkingBytes: networking,
            gpuBytes: gpu,
            childrenBytes: children,
            childCount: count
        )
    }

    /// Same counter as TASK_VM_INFO.phys_footprint, without a task port.
    static func physFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }

    private static func listPids() -> [pid_t] {
        let bytesNeeded = proc_listallpids(nil, 0)
        guard bytesNeeded > 0 else { return [] }
        let count = Int(bytesNeeded) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: count)
        let filledBytes = pids.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(buffer.count))
        }
        guard filledBytes > 0 else { return [] }
        let n = Int(filledBytes) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(max(0, n))).filter { $0 > 0 }
    }

    private static func isAppHelper(pid: pid_t, appPid: pid_t, uid: uid_t, baseline: Set<pid_t>) -> Bool {
        let related = parentPid(pid) == appPid || responsiblePid(pid) == appPid
        if related && looksLikeWebKit(pid: pid) {
            return true
        }
        guard processUid(pid) == uid else { return false }
        guard !baseline.contains(pid) else { return false }
        let name = processName(pid)
        let path = processPath(pid)
        return WebKitHelperKind.isWebKitHelper(name: name, path: path)
    }

    private static func looksLikeWebKit(pid: pid_t) -> Bool {
        let name = processName(pid)
        let path = processPath(pid)
        if WebKitHelperKind.isWebKitHelper(name: name, path: path) { return true }
        let lower = name.lowercased()
        if lower.contains("webkit") { return true }
        if name.contains("WebContent") { return true }
        if lower.contains("networking") { return true }
        if lower.contains("gpu") { return true }
        return false
    }

    private static func kind(pid: pid_t) -> WebKitHelperKind? {
        if let fromPath = WebKitHelperKind.classify(nameOrPath: processPath(pid)) {
            return fromPath
        }
        return WebKitHelperKind.classify(nameOrPath: processName(pid))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func parentPid(_ pid: pid_t) -> pid_t {
        shortInfo(pid)?.ppid ?? 0
    }

    private static func processUid(_ pid: pid_t) -> uid_t {
        shortInfo(pid)?.uid ?? 0
    }

    private static func shortInfo(_ pid: pid_t) -> (ppid: pid_t, uid: uid_t)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let got = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, ptr, size)
        }
        guard got == size else { return nil }
        return (pid_t(info.pbsi_ppid), uid_t(info.pbsi_uid))
    }

    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePid(_ pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return 0 }
        return fn(pid)
    }
}
