// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Unique download file names. Foundation only.
public enum DownloadNaming {
    /// Last path component, no separators, no leading dots, no trailing dot or space.
    /// Control characters and bidi overrides are removed. Empty input becomes `download`.
    /// The result stays within 240 UTF-8 bytes and keeps its real extension.
    public static func sanitize(_ raw: String) -> String {
        var name = DirectionalText.strippingControls(raw)
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
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            return "download"
        }
        return capUTF8(name, maxBytes: 240)
    }

    /// Keep the extension so a truncated name cannot hide `.command` or `.app`.
    private static func capUTF8(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let parts = splitStemExtension(name)
        var ext = parts.ext
        if ext.utf8.count > 32 {
            ext = String(ext.prefix(32))
        }
        let budget = maxBytes - ext.utf8.count
        guard budget > 0 else { return "download" }
        var stem = parts.stem
        while stem.utf8.count > budget, !stem.isEmpty {
            stem.removeLast()
        }
        if stem.isEmpty {
            return "download" + ext
        }
        return stem + ext
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

/// "Open after download" opens only these inert types. Anything else stays closed,
/// including an extension this list does not name. A trailing dot or space does not
/// hide the real extension.
public enum DownloadOpenPolicy {
    public static let allowedExtensions: Set<String> = [
        "pdf",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff",
        "txt", "md", "csv", "json",
        "mp3", "m4a", "wav", "mp4", "mov", "m4v",
    ]

    /// Last path extension after control characters and trailing dots or spaces are removed.
    static func normalizedExtension(_ filename: String) -> String {
        var name = DirectionalText.strippingControls(filename)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        return (name as NSString).pathExtension.lowercased()
    }

    public static func allowsAutomaticOpen(filename: String, isDirectory: Bool, isExecutable: Bool) -> Bool {
        if isDirectory || isExecutable { return false }
        return allowedExtensions.contains(normalizedExtension(filename))
    }
}

/// Stop a download before it consumes the last free space on the volume.
public enum DownloadSpacePolicy {
    public static let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    public static func shouldCancel(freeBytes: Int64?, expectedBytes: Int64? = nil, minimumFreeBytes: Int64 = minimumFreeBytes) -> Bool {
        guard let freeBytes else { return false }
        if freeBytes < minimumFreeBytes { return true }
        if let expectedBytes, expectedBytes > 0 {
            if expectedBytes > freeBytes { return true }
            if freeBytes - expectedBytes < minimumFreeBytes { return true }
        }
        return false
    }
}

/// Value written to `com.apple.quarantine` on a finished download.
public enum QuarantineAttribute {
    public static let name = "com.apple.quarantine"

    public static func value(unixTime: UInt64, uuid: UUID) -> String {
        "0083;\(String(unixTime, radix: 16));\(AppInfo.shortName);\(uuid.uuidString)"
    }
}
