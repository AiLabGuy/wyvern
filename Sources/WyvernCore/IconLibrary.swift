// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension Notification.Name {
    /// Posted after the icon index changes. The object is the library.
    static let wyvernIconsDidChange = Notification.Name("\(AppInfo.bundleIdentifier).iconsDidChange")
}

/// Built-in Dock icon. `default` is the bundle icon from `assets/icon`, unchanged.
public enum AppIconStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case `default`
    case graphite
    case hermes
    case neon
}

/// What the Dock should show. A custom image is a file name inside the Icons folder.
public enum StoredAppIcon: Equatable, Sendable {
    case style(AppIconStyle)
    case custom(fileName: String)
}

/// JSON index of the app icon choice, bookmark id → file, and host → file.
/// A file that does not decode is an empty catalog. Callers do not repair it in place
/// until the next successful save.
public struct IconCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var appIcon: String
    public var appIconFile: String?
    public var bookmarks: [String: String]
    public var hosts: [String: String]

    public init(
        version: Int = 1,
        appIcon: String = AppIconStyle.default.rawValue,
        appIconFile: String? = nil,
        bookmarks: [String: String] = [:],
        hosts: [String: String] = [:]
    ) {
        self.version = version
        self.appIcon = appIcon
        self.appIconFile = appIconFile
        self.bookmarks = bookmarks
        self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case appIcon
        case appIconFile
        case bookmarks
        case hosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        appIcon = try container.decodeIfPresent(String.self, forKey: .appIcon) ?? AppIconStyle.default.rawValue
        appIconFile = try container.decodeIfPresent(String.self, forKey: .appIconFile)
        bookmarks = try container.decodeIfPresent([String: String].self, forKey: .bookmarks) ?? [:]
        hosts = try container.decodeIfPresent([String: String].self, forKey: .hosts) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(appIcon, forKey: .appIcon)
        try container.encodeIfPresent(appIconFile, forKey: .appIconFile)
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encode(hosts, forKey: .hosts)
    }
}

/// Icons folder under Application Support (`Icons/`, mode 0700).
/// Files are UUID names ending in `.png`, mode 0600, written by `PrivateFile`.
/// Callers use one library from one thread. The app uses it on the main thread.
public final class IconLibrary {
    public static let folderName = "Icons"
    public static let indexFileName = "index.json"

    public let directory: URL
    public let indexURL: URL
    private var catalog: IconCatalog

    public init(directory dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        indexURL = directory.appendingPathComponent(Self.indexFileName)
        catalog = Self.loadCatalog(at: indexURL)
    }

    public convenience init() {
        self.init(directory: AppLocations.dataDirectory)
    }

    public var appIcon: StoredAppIcon {
        switch catalog.appIcon {
        case AppIconStyle.graphite.rawValue:
            return .style(.graphite)
        case AppIconStyle.hermes.rawValue:
            return .style(.hermes)
        case AppIconStyle.neon.rawValue:
            return .style(.neon)
        case "custom":
            if let name = catalog.appIconFile, IconUpload.isStoredFileName(name) {
                return .custom(fileName: name)
            }
            return .style(.default)
        default:
            return .style(.default)
        }
    }

    public func bookmarkIconURL(id: UUID) -> URL? {
        guard let name = catalog.bookmarks[canonical(id)] else { return nil }
        return existingFile(named: name)
    }

    public func hostIconURL(key: String) -> URL? {
        guard let name = catalog.hosts[key] else { return nil }
        return existingFile(named: name)
    }

    public func hostKeys() -> [String] {
        catalog.hosts.keys.sorted()
    }

    public func customAppIconURL() -> URL? {
        guard case .custom(let name) = appIcon else { return nil }
        return existingFile(named: name)
    }

    @discardableResult
    public func setBuiltInAppIcon(_ style: AppIconStyle) -> Result<Void, IconUploadError> {
        let previous = catalog.appIconFile
        if catalog.appIcon == style.rawValue && previous == nil {
            return .success(())
        }
        let snapshot = catalog
        catalog.appIcon = style.rawValue
        catalog.appIconFile = nil
        guard save() else {
            catalog = snapshot
            return .failure(.writeFailed)
        }
        if let previous {
            removeFile(named: previous)
        }
        postChange()
        return .success(())
    }

    /// Deletes a custom app-icon file and returns to the bundle icon.
    @discardableResult
    public func resetAppIcon() -> Result<Void, IconUploadError> {
        setBuiltInAppIcon(.default)
    }

    /// Stores PNG bytes that `IconUpload` already re-encoded. The name is a new UUID.
    @discardableResult
    public func installPreparedPNG(_ png: Data, forBookmark id: UUID) -> Result<Void, IconUploadError> {
        let key = canonical(id)
        let previous = catalog.bookmarks[key]
        switch assign(png, previous: previous, write: { name in
            self.catalog.bookmarks[key] = name
        }) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return .success(())
        }
    }

    @discardableResult
    public func installFile(at url: URL, forBookmark id: UUID) -> Result<Void, IconUploadError> {
        switch IconUpload.preparedPNG(from: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let png):
            return installPreparedPNG(png, forBookmark: id)
        }
    }

    public func resetBookmarkIcon(id: UUID) {
        let key = canonical(id)
        guard let name = catalog.bookmarks[key] else { return }
        let snapshot = catalog
        catalog.bookmarks.removeValue(forKey: key)
        guard save() else {
            catalog = snapshot
            return
        }
        removeFile(named: name)
        postChange()
    }

    /// Drops icons whose bookmark id is gone, and deletes those files.
    public func pruneBookmarks(keeping ids: Set<UUID>) {
        let keep = Set(ids.map(canonical))
        let stale = catalog.bookmarks.keys.filter { keep.contains($0) == false }
        guard !stale.isEmpty else { return }
        let snapshot = catalog
        var removed: [String] = []
        for key in stale {
            if let name = catalog.bookmarks.removeValue(forKey: key) {
                removed.append(name)
            }
        }
        guard save() else {
            catalog = snapshot
            return
        }
        for name in removed {
            removeFile(named: name)
        }
        postChange()
    }

    /// Returns the normalized host key that was stored.
    @discardableResult
    public func installPreparedPNG(_ png: Data, forHost raw: String) -> Result<String, IconUploadError> {
        guard let key = IconHostKey.normalize(raw) else {
            return .failure(.invalidHost)
        }
        let previous = catalog.hosts[key]
        switch assign(png, previous: previous, write: { name in
            self.catalog.hosts[key] = name
        }) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return .success(key)
        }
    }

    @discardableResult
    public func installFile(at url: URL, forHost raw: String) -> Result<String, IconUploadError> {
        switch IconUpload.preparedPNG(from: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let png):
            return installPreparedPNG(png, forHost: raw)
        }
    }

    @discardableResult
    public func installPreparedPNGForAppIcon(_ png: Data) -> Result<Void, IconUploadError> {
        let previous = catalog.appIcon == "custom" ? catalog.appIconFile : nil
        switch assign(png, previous: previous, write: { name in
            self.catalog.appIcon = "custom"
            self.catalog.appIconFile = name
        }) {
        case .failure(let error):
            return .failure(error)
        case .success:
            return .success(())
        }
    }

    @discardableResult
    public func installFileForAppIcon(at url: URL) -> Result<Void, IconUploadError> {
        switch IconUpload.preparedPNG(from: url) {
        case .failure(let error):
            return .failure(error)
        case .success(let png):
            return installPreparedPNGForAppIcon(png)
        }
    }

    public func resetHostIcon(_ raw: String) {
        guard let key = IconHostKey.normalize(raw) ?? (catalog.hosts[raw] == nil ? nil : raw) else {
            return
        }
        guard let name = catalog.hosts[key] else { return }
        let snapshot = catalog
        catalog.hosts.removeValue(forKey: key)
        guard save() else {
            catalog = snapshot
            return
        }
        removeFile(named: name)
        postChange()
    }

    private func assign(
        _ png: Data,
        previous: String?,
        write: (String) -> Void
    ) -> Result<Void, IconUploadError> {
        guard !png.isEmpty else { return .failure(.empty) }
        guard png.count <= IconUpload.maxBytes else { return .failure(.tooLarge) }
        guard IconUpload.detectedKind(data: png) == .png else { return .failure(.unsupportedType) }
        let snapshot = catalog
        switch storeNewFile(png) {
        case .failure(let error):
            return .failure(error)
        case .success(let name):
            write(name)
            guard save() else {
                catalog = snapshot
                removeFile(named: name)
                return .failure(.writeFailed)
            }
            if let previous, previous != name {
                removeFile(named: previous)
            }
            postChange()
            return .success(())
        }
    }

    private func storeNewFile(_ png: Data) -> Result<String, IconUploadError> {
        let name = UUID().uuidString.lowercased() + ".png"
        guard IconUpload.isStoredFileName(name), let url = fileURL(named: name) else {
            return .failure(.writeFailed)
        }
        do {
            try PrivateFile.write(png, to: url)
        } catch {
            return .failure(.writeFailed)
        }
        return .success(name)
    }

    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(catalog) else { return false }
        do {
            try PrivateFile.ensureDirectory(directory)
            try PrivateFile.write(data, to: indexURL)
            return true
        } catch {
            return false
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .wyvernIconsDidChange, object: self)
    }

    private func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func fileURL(named name: String) -> URL? {
        guard IconUpload.isStoredFileName(name) else { return nil }
        let url = directory.appendingPathComponent(name)
        let folder = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return url
    }

    private func existingFile(named name: String) -> URL? {
        guard let url = fileURL(named: name) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeFile(named name: String) {
        guard let url = fileURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadCatalog(at url: URL) -> IconCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return IconCatalog()
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return IconCatalog()
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            return IconCatalog()
        }
        guard let decoded = try? JSONDecoder().decode(IconCatalog.self, from: data) else {
            return IconCatalog()
        }
        return sanitize(decoded)
    }

    private static func sanitize(_ catalog: IconCatalog) -> IconCatalog {
        var copy = catalog
        switch catalog.appIcon {
        case AppIconStyle.default.rawValue, AppIconStyle.graphite.rawValue,
             AppIconStyle.hermes.rawValue, AppIconStyle.neon.rawValue:
            copy.appIconFile = nil
        case "custom":
            if let name = catalog.appIconFile, IconUpload.isStoredFileName(name) {
                copy.appIconFile = name
            } else {
                copy.appIcon = AppIconStyle.default.rawValue
                copy.appIconFile = nil
            }
        default:
            copy.appIcon = AppIconStyle.default.rawValue
            copy.appIconFile = nil
        }
        var bookmarks: [String: String] = [:]
        for (key, name) in catalog.bookmarks {
            guard let id = UUID(uuidString: key), IconUpload.isStoredFileName(name) else { continue }
            bookmarks[id.uuidString.lowercased()] = name
        }
        copy.bookmarks = bookmarks
        var hosts: [String: String] = [:]
        for (key, name) in catalog.hosts {
            guard let normalized = IconHostKey.normalize(key), IconUpload.isStoredFileName(name) else { continue }
            if hosts[normalized] == nil {
                hosts[normalized] = name
            }
        }
        copy.hosts = hosts
        return copy
    }
}
