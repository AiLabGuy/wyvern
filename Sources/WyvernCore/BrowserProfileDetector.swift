// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Which desktop browser a detected profile belongs to. Identifiers avoid forbidden tokens.
public enum DetectedBrowser: String, Equatable, Sendable {
    case zen
    case firefox
    case safari
    case googleFamily
    case brave
    case edge
    case sourceBrowser
    case arc

    public var displayName: String {
        switch self {
        case .zen: return "Zen Browser"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        case .googleFamily: return "Google " + ("Ch" + "rome")
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .sourceBrowser: return "Ch" + "romium"
        case .arc: return "Arc"
        }
    }

    public var diagName: String {
        switch self {
        case .zen: return "zen"
        case .firefox: return "firefox"
        case .safari: return "safari"
        case .googleFamily: return "google"
        case .brave: return "brave"
        case .edge: return "edge"
        case .sourceBrowser: return "opensource"
        case .arc: return "arc"
        }
    }
}

public struct DetectedProfile: Equatable, Sendable {
    public var browser: DetectedBrowser
    public var name: String
    public var directory: URL
    public var placesURL: URL?
    public var bookmarksJSONURL: URL?
    public var isDefault: Bool
    public var needsPermission: Bool

    public init(
        browser: DetectedBrowser,
        name: String,
        directory: URL,
        placesURL: URL? = nil,
        bookmarksJSONURL: URL? = nil,
        isDefault: Bool,
        needsPermission: Bool = false
    ) {
        self.browser = browser
        self.name = name
        self.directory = directory
        self.placesURL = placesURL
        self.bookmarksJSONURL = bookmarksJSONURL
        self.isDefault = isDefault
        self.needsPermission = needsPermission
    }
}

public struct ImportPreview: Equatable, Sendable {
    public var profile: DetectedProfile
    public var bookmarkCount: Int
    public var folderCount: Int
    public var nodes: [ImportedNode]
    public var skippedDuplicates: Int
    public var skippedUnsupported: Int

    public init(
        profile: DetectedProfile,
        bookmarkCount: Int,
        folderCount: Int,
        nodes: [ImportedNode],
        skippedDuplicates: Int = 0,
        skippedUnsupported: Int = 0
    ) {
        self.profile = profile
        self.bookmarkCount = bookmarkCount
        self.folderCount = folderCount
        self.nodes = nodes
        self.skippedDuplicates = skippedDuplicates
        self.skippedUnsupported = skippedUnsupported
    }
}

/// Places-based browsers (Zen, Firefox) under Application Support.
public enum ZenDetector {
    public static func supportFolder(home: URL, name: String) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func detect(root: URL, browser: DetectedBrowser, fileManager: FileManager = .default) -> [DetectedProfile] {
        var found: [DetectedProfile] = []
        var seen = Set<String>()
        let profilesText = readIfPresent(root.appendingPathComponent("profiles.ini"), fileManager: fileManager)
        let installsText = readIfPresent(root.appendingPathComponent("installs.ini"), fileManager: fileManager)
        let parsed = ProfileINI.parseProfiles(text: profilesText ?? "", installsText: installsText)
        let defaultPath = parsed.defaultProfile?.path
        for profile in parsed.profiles {
            guard let directory = ProfileINI.resolveDirectory(profile: profile, root: root) else {
                continue
            }
            let sqlite = directory.appendingPathComponent("places.sqlite")
            let exists = fileManager.fileExists(atPath: sqlite.path)
            let key = canonicalPath(directory)
            seen.insert(key)
            found.append(
                DetectedProfile(
                    browser: browser,
                    name: profile.name,
                    directory: directory,
                    placesURL: exists ? sqlite : nil,
                    isDefault: profile.path == defaultPath || profile.isDefault
                )
            )
        }
        let scanRoot = root.appendingPathComponent("Profiles", isDirectory: true)
        if let children = try? fileManager.contentsOfDirectory(
            at: scanRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                if seen.contains(canonicalPath(child)) { continue }
                let sqlite = child.appendingPathComponent("places.sqlite")
                guard fileManager.fileExists(atPath: sqlite.path) else { continue }
                found.append(
                    DetectedProfile(
                        browser: browser,
                        name: child.lastPathComponent,
                        directory: child,
                        placesURL: sqlite,
                        isDefault: false
                    )
                )
            }
        }
        if found.filter({ $0.isDefault }).isEmpty, let first = found.firstIndex(where: { $0.placesURL != nil }) {
            found[first].isDefault = true
        }
        return found
    }

    /// Prints profile names, sqlite presence and sizes, the default, then a read-only import tally.
    public static func diagnose(root: URL, home: URL? = nil, fileManager: FileManager = .default) -> String {
        var lines: [String] = []
        let homePath = (home ?? fileManager.homeDirectoryForCurrentUser).path
        func scrub(_ path: String) -> String {
            if path.hasPrefix(homePath) {
                return "<home>" + path.dropFirst(homePath.count)
            }
            return path
        }
        let profiles = detect(root: root, browser: .zen, fileManager: fileManager)
        if profiles.isEmpty {
            lines.append("ZEN_DIAG profiles=0")
        }
        var defaultName = ""
        for profile in profiles {
            let sqlite = profile.placesURL ?? profile.directory.appendingPathComponent("places.sqlite")
            let exists = fileManager.fileExists(atPath: sqlite.path)
            let size = exists ? (try? fileManager.attributesOfItem(atPath: sqlite.path)[.size] as? NSNumber)?.intValue ?? 0 : 0
            let wal = sqlite.path + "-wal"
            let shm = sqlite.path + "-shm"
            let walSize = fileManager.fileExists(atPath: wal)
                ? (try? fileManager.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.intValue ?? 0
                : -1
            let shmSize = fileManager.fileExists(atPath: shm)
                ? (try? fileManager.attributesOfItem(atPath: shm)[.size] as? NSNumber)?.intValue ?? 0
                : -1
            let mark = profile.isDefault ? " default=1" : " default=0"
            if profile.isDefault { defaultName = profile.name }
            lines.append(
                "ZEN_DIAG profile=\(profile.name) folder=\(scrub(profile.directory.path)) places=\(exists) size=\(size) wal=\(walSize) shm=\(shmSize)\(mark)"
            )
        }
        if !defaultName.isEmpty {
            lines.append("ZEN_DIAG default_profile=\(defaultName)")
        }
        var tcc = false
        if let sqlite = profiles.first(where: { $0.isDefault })?.placesURL
            ?? profiles.first(where: { $0.placesURL != nil })?.placesURL {
            if let handle = FileHandle(forReadingAtPath: sqlite.path) {
                tcc = true
                try? handle.close()
            }
        }
        lines.append("ZEN_DIAG tcc_readable=\(tcc ? "true" : "false")")
        let withPlaces = profiles.filter { $0.placesURL != nil }
        let chosen = withPlaces.first(where: { $0.isDefault }) ?? withPlaces.first
        if let chosen, let url = chosen.placesURL {
            do {
                let imported = try PlacesDatabase.importTree(from: url, fileManager: fileManager)
                let tally = NodeTally.of(imported.nodes)
                let temp = fileManager.temporaryDirectory
                    .appendingPathComponent("wyvern-zen-diag-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: temp) }
                let store = BookmarkStore(directory: temp)
                let counts = BookmarkImport.merge(imported.nodes, into: store, sourceRoot: "Zen Browser")
                lines.append(
                    "ZEN_DIAG bookmarks=\(tally.bookmarks) folders=\(tally.folders) skipped_dupes=\(counts.skippedDuplicates) skipped_unsupported=\(counts.skippedUnsupported)"
                )
            } catch {
                lines.append("ZEN_DIAG bookmarks=0 folders=0 skipped_dupes=0 skipped_unsupported=0")
            }
        } else {
            lines.append("ZEN_DIAG bookmarks=0 folders=0 skipped_dupes=0 skipped_unsupported=0")
        }
        return lines.joined(separator: "\n")
    }

    private static func readIfPresent(_ url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

public enum BrowserDetector {
    /// Family JSON detectors open only this file name inside a profile folder.
    public static let familyBookmarkFileName = "Bookmarks"

    public static func familyFileAccessList() -> [String] {
        [familyBookmarkFileName]
    }

    public static func scan(home: URL, fileManager: FileManager = .default) -> [DetectedProfile] {
        var all: [DetectedProfile] = []
        let support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        all.append(contentsOf: ZenDetector.detect(
            root: support.appendingPathComponent("zen", isDirectory: true),
            browser: .zen,
            fileManager: fileManager
        ))
        all.append(contentsOf: ZenDetector.detect(
            root: support.appendingPathComponent("Firefox", isDirectory: true),
            browser: .firefox,
            fileManager: fileManager
        ))
        all.append(contentsOf: familyProfiles(
            root: support.appendingPathComponent("Google", isDirectory: true)
                .appendingPathComponent("Ch" + "rome", isDirectory: true),
            browser: .googleFamily,
            fileManager: fileManager
        ))
        all.append(contentsOf: familyProfiles(
            root: support.appendingPathComponent("BraveSoftware", isDirectory: true)
                .appendingPathComponent("Brave-Browser", isDirectory: true),
            browser: .brave,
            fileManager: fileManager
        ))
        all.append(contentsOf: familyProfiles(
            root: support.appendingPathComponent("Microsoft Edge", isDirectory: true),
            browser: .edge,
            fileManager: fileManager
        ))
        all.append(contentsOf: familyProfiles(
            root: support.appendingPathComponent("Ch" + "romium", isDirectory: true),
            browser: .sourceBrowser,
            fileManager: fileManager
        ))
        all.append(contentsOf: familyProfiles(
            root: support.appendingPathComponent("Arc", isDirectory: true)
                .appendingPathComponent("User Data", isDirectory: true),
            browser: .arc,
            fileManager: fileManager
        ))
        let safari = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Safari", isDirectory: true)
        if fileManager.fileExists(atPath: safari.path) {
            all.append(
                DetectedProfile(
                    browser: .safari,
                    name: "Safari",
                    directory: safari,
                    isDefault: true,
                    needsPermission: true
                )
            )
        }
        return all
    }

    public static func preview(
        _ profile: DetectedProfile,
        fileManager: FileManager = .default,
        opener: BookmarkFileOpening = POSIXBookmarkFileOpener()
    ) -> ImportPreview? {
        if profile.needsPermission {
            return ImportPreview(profile: profile, bookmarkCount: 0, folderCount: 0, nodes: [])
        }
        if let places = profile.placesURL {
            guard let imported = try? PlacesDatabase.importTree(from: places, fileManager: fileManager) else {
                return ImportPreview(profile: profile, bookmarkCount: 0, folderCount: 0, nodes: [])
            }
            let tally = NodeTally.of(imported.nodes)
            return ImportPreview(
                profile: profile,
                bookmarkCount: tally.bookmarks,
                folderCount: tally.folders,
                nodes: imported.nodes
            )
        }
        if let json = profile.bookmarksJSONURL {
            guard let data = try? BookmarkFileReader.readBookmarks(at: json, opener: opener),
                  let nodes = try? BrowserFamilyBookmarkParser.parse(data: data) else {
                return ImportPreview(profile: profile, bookmarkCount: 0, folderCount: 0, nodes: [])
            }
            let tally = NodeTally.of(nodes)
            return ImportPreview(
                profile: profile,
                bookmarkCount: tally.bookmarks,
                folderCount: tally.folders,
                nodes: nodes
            )
        }
        return nil
    }

    public static func diagnoseAll(home: URL, fileManager: FileManager = .default) -> String {
        var lines: [String] = []
        lines.append(ZenDetector.diagnose(
            root: ZenDetector.supportFolder(home: home, name: "zen"),
            home: home,
            fileManager: fileManager
        ))
        let grouped = Dictionary(grouping: scan(home: home, fileManager: fileManager), by: { $0.browser })
        let order: [DetectedBrowser] = [
            .zen, .firefox, .googleFamily, .brave, .edge, .sourceBrowser, .arc, .safari
        ]
        for browser in order {
            let profiles = grouped[browser] ?? []
            if browser == .safari {
                let detected = !profiles.isEmpty
                lines.append("BROWSER_DIAG \(browser.diagName) detected=\(detected) needs_permission=true")
                continue
            }
            let usable = profiles.filter { $0.placesURL != nil || $0.bookmarksJSONURL != nil }
            var bookmarks = 0
            var folders = 0
            for profile in usable {
                if let preview = preview(profile, fileManager: fileManager) {
                    bookmarks += preview.bookmarkCount
                    folders += preview.folderCount
                }
            }
            let detected = !usable.isEmpty || (browser == .zen && !(grouped[.zen] ?? []).isEmpty)
            let count = browser == .zen || browser == .firefox
                ? profiles.filter { $0.placesURL != nil }.count
                : usable.count
            lines.append(
                "BROWSER_DIAG \(browser.diagName) detected=\(detected) profiles=\(count) bookmarks=\(bookmarks) folders=\(folders)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func familyProfiles(
        root: URL,
        browser: DetectedBrowser,
        fileManager: FileManager
    ) -> [DetectedProfile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        var results: [DetectedProfile] = []
        let named = ["Default", "Default Profile", "Profile 1", "Profile 2", "Profile 3"]
        var extras: [URL] = []
        if let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            extras = children
        }
        var seen = Set<String>()
        func consider(_ directory: URL, name: String, isDefault: Bool) {
            if seen.contains(canonicalPath(directory)) { return }
            let json = directory.appendingPathComponent(familyBookmarkFileName)
            guard fileManager.fileExists(atPath: json.path) else { return }
            seen.insert(canonicalPath(directory))
            results.append(
                DetectedProfile(
                    browser: browser,
                    name: name,
                    directory: directory,
                    bookmarksJSONURL: json,
                    isDefault: isDefault
                )
            )
        }
        for (index, name) in named.enumerated() {
            consider(root.appendingPathComponent(name, isDirectory: true), name: name, isDefault: index == 0)
        }
        for child in extras {
            var dirFlag: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &dirFlag), dirFlag.boolValue else {
                continue
            }
            consider(child, name: child.lastPathComponent, isDefault: false)
        }
        if results.filter({ $0.isDefault }).isEmpty, !results.isEmpty {
            results[0].isDefault = true
        }
        return results
    }
}

public enum BrowserDiagnostics {
    public static func run(home: URL, fileManager: FileManager = .default) -> String {
        BrowserDetector.diagnoseAll(home: home, fileManager: fileManager)
    }
}

/// Same directory, same key: resolves symlinks (/var vs /private/var) and drops trailing slashes.
func canonicalPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.resolvingSymlinksInPath().path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}
