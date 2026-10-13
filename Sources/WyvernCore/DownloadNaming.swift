// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Unique download file names. Foundation only.
public enum DownloadNaming {
    /// Last path component, no separators, no leading dots. Empty input becomes `download`.
    public static func sanitize(_ raw: String) -> String {
        var name = raw
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let slash = name.lastIndex(of: "\\") {
            name = String(name[name.index(after: slash)...])
        }
        name = name.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: "\\", with: "_")
        name = name.replacingOccurrences(of: ":", with: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.isEmpty {
            return "download"
        }
        return name
    }

    /// `name.ext`, then `name (1).ext`, `name (2).ext`. A `.tar.gz` (and similar) stays the extension.
    public static func uniqueName(desired: String, occupied: Set<String>) -> String {
        allocate(desired: desired, occupied: occupied).finalName
    }

    /// Final name plus the in-progress `*.download` sibling, both free in `occupied`.
    public static func allocate(desired: String, occupied: Set<String>) -> (finalName: String, tempName: String) {
        let taken = Set(occupied.map { $0.lowercased() })
        let base = sanitize(desired)
        var index = 0
        while true {
            let name = index == 0 ? base : numbered(base, index)
            let temp = name + ".download"
            if !taken.contains(name.lowercased()), !taken.contains(temp.lowercased()) {
                return (name, temp)
            }
            index += 1
        }
    }

    public static func splitStemExtension(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        let compounds = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.z"]
        for suffix in compounds {
            if lower.hasSuffix(suffix), name.count > suffix.count {
                let stem = String(name.dropLast(suffix.count))
                if stem.isEmpty {
                    return ("download", String(name.suffix(suffix.count)))
                }
                return (stem, String(name.suffix(suffix.count)))
            }
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return (String(name[..<dot]), String(name[dot...]))
        }
        return (name, "")
    }

    private static func numbered(_ name: String, _ index: Int) -> String {
        let parts = splitStemExtension(name)
        return "\(parts.stem) (\(index))\(parts.ext)"
    }
}

/// Value written to `com.apple.quarantine` on a finished download.
public enum QuarantineAttribute {
    public static let name = "com.apple.quarantine"

    public static func value(unixTime: UInt64, uuid: UUID) -> String {
        "0083;\(String(unixTime, radix: 16));\(AppInfo.shortName);\(uuid.uuidString)"
    }
}
