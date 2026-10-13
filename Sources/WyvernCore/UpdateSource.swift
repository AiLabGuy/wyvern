// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum UpdateSourceError: Error, Equatable, Sendable {
    /// This build has no built-in feed URL.
    case notConfigured
    case emptyURL
    case malformedURL
    case credentialsInURL
    /// `http://` in a build without `WYVERN_DEV_UPDATER`, or without a dev request.
    case httpRejected
    /// `http://` to a host outside the private IPv4 ranges, in a dev build.
    case publicHTTPRejected
    case missingKey
    case malformedKey
}

/// Where updates come from, and the only key that may sign them.
public struct UpdateSource: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case builtIn
        case custom
    }

    public var feedURL: URL
    public var publicKey: Minisign.PublicKey
    public var origin: Origin
    /// True only in `WYVERN_DEV_UPDATER` builds whose source asked for private-network HTTP.
    public var allowsDevHTTP: Bool

    public init(feedURL: URL, publicKey: Minisign.PublicKey, origin: Origin, allowsDevHTTP: Bool) {
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.origin = origin
        self.allowsDevHTTP = allowsDevHTTP
    }

    public var keyFingerprint: String { publicKey.fingerprint }
}

public enum UpdateSourceValidator {
    /// Accepts the base64 key line alone, or a whole minisign `.pub` file
    /// (an `untrusted comment:` line followed by the key line).
    public static func parseKey(_ text: String) -> Result<Minisign.PublicKey, UpdateSourceError> {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let keyLines = lines.filter { !$0.lowercased().hasPrefix("untrusted comment:") }
        guard !keyLines.isEmpty else { return .failure(.missingKey) }
        guard keyLines.count == 1, let key = Minisign.PublicKey.parse(keyLines[0]) else {
            return .failure(.malformedKey)
        }
        return .success(key)
    }

    /// Both parts are required. A source is never accepted without its key.
    public static func validate(
        urlText: String,
        keyText: String,
        origin: UpdateSource.Origin,
        allowsDevHTTP: Bool
    ) -> Result<UpdateSource, UpdateSourceError> {
        let url: URL
        switch UpdateTransportPolicy.parseSourceURL(urlText, allowsDevHTTP: allowsDevHTTP) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            url = value
        }
        switch parseKey(keyText) {
        case .failure(let error):
            return .failure(error)
        case .success(let key):
            let devHTTP = url.scheme?.lowercased() == "http"
            return .success(UpdateSource(feedURL: url, publicKey: key, origin: origin, allowsDevHTTP: devHTTP))
        }
    }
}

/// The subset of `UserDefaults` the store uses. Tests inject an in-memory copy.
public protocol UpdateSourceDefaults: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: UpdateSourceDefaults {}

/// Built-in source from Info.plist, optionally replaced by a custom source in user defaults.
/// A custom source is stored only as a validated URL and key pair.
public final class UpdateSourceStore {
    public static let customURLKey = "updates.customSourceURL"
    public static let customKeyKey = "updates.customSourcePublicKey"

    private let defaults: UpdateSourceDefaults
    private let info: [String: Any]
    private let compiled: Bool

    public init(
        defaults: UpdateSourceDefaults,
        info: [String: Any],
        isDevUpdaterCompiled compiled: Bool = isDevUpdaterCompiled
    ) {
        self.defaults = defaults
        self.info = info
        self.compiled = compiled
    }

    public var hasCustomSource: Bool {
        !(defaults.string(forKey: Self.customURLKey) ?? "").isEmpty
            || !(defaults.string(forKey: Self.customKeyKey) ?? "").isEmpty
    }

    /// Raw built-in values for display in Settings.
    public var builtInURLText: String { string("WyvernUpdateFeedURL") }
    public var builtInKeyText: String { string("WyvernUpdatePublicKey") }

    public func builtIn() -> Result<UpdateSource, UpdateSourceError> {
        let urlText = builtInURLText
        guard !urlText.isEmpty else { return .failure(.notConfigured) }
        #if WYVERN_DEV_UPDATER
        _ = "WYVERN_DEV_SOURCE"
        let devRequested = compiled && string("WyvernUpdateDevSource") == "1"
        #else
        let devRequested = false
        #endif
        return UpdateSourceValidator.validate(
            urlText: urlText,
            keyText: builtInKeyText,
            origin: .builtIn,
            allowsDevHTTP: devRequested
        )
    }

    /// The custom source when one is stored, else the built-in one.
    /// A stored custom source that no longer validates is an error, never a silent fallback.
    public func current() -> Result<UpdateSource, UpdateSourceError> {
        guard hasCustomSource else { return builtIn() }
        return UpdateSourceValidator.validate(
            urlText: defaults.string(forKey: Self.customURLKey) ?? "",
            keyText: defaults.string(forKey: Self.customKeyKey) ?? "",
            origin: .custom,
            allowsDevHTTP: compiled
        )
    }

    /// Validates both fields and stores them together. Nothing is written on failure.
    /// Values equal to the built-in source clear the custom entry instead.
    @discardableResult
    public func saveCustom(urlText: String, keyText: String) -> Result<UpdateSource, UpdateSourceError> {
        let result = UpdateSourceValidator.validate(
            urlText: urlText,
            keyText: keyText,
            origin: .custom,
            allowsDevHTTP: compiled
        )
        guard case .success(let source) = result else { return result }
        if case .success(let defaultSource) = builtIn(),
           defaultSource.feedURL == source.feedURL,
           defaultSource.publicKey == source.publicKey {
            resetToDefault()
            return .success(defaultSource)
        }
        defaults.set(source.feedURL.absoluteString, forKey: Self.customURLKey)
        defaults.set(source.publicKey.encoded, forKey: Self.customKeyKey)
        return .success(source)
    }

    public func resetToDefault() {
        defaults.removeObject(forKey: Self.customURLKey)
        defaults.removeObject(forKey: Self.customKeyKey)
    }

    private func string(_ key: String) -> String {
        (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
