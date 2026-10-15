// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct NavigationRequest: Equatable, Sendable {
    public var url: URL
    public var isMainFrame: Bool
    /// The file URL the person typed, when the current document was opened that way.
    public var userTypedFileURL: URL?
    public var currentPageURL: URL?

    public init(
        url: URL,
        isMainFrame: Bool,
        userTypedFileURL: URL? = nil,
        currentPageURL: URL? = nil
    ) {
        self.url = url
        self.isMainFrame = isMainFrame
        self.userTypedFileURL = userTypedFileURL
        self.currentPageURL = currentPageURL
    }
}

public enum NavigationDecision: Equatable, Sendable {
    /// Load inside the web view.
    case allow
    /// Drop the navigation. Used for javascript and data.
    case cancel
    /// Ask, then hand the URL to the system opener.
    case confirmExternal
    /// A file URL that was not typed by the person.
    case denyFile
}

public struct ResponseInput: Equatable, Sendable {
    public var isMainFrame: Bool
    public var canShowMIMEType: Bool
    public var mimeType: String
    public var statusCode: Int
    public var contentDisposition: String?
    public var userInitiated: Bool

    public init(
        isMainFrame: Bool,
        canShowMIMEType: Bool,
        mimeType: String,
        statusCode: Int,
        contentDisposition: String?,
        userInitiated: Bool
    ) {
        self.isMainFrame = isMainFrame
        self.canShowMIMEType = canShowMIMEType
        self.mimeType = mimeType
        self.statusCode = statusCode
        self.contentDisposition = contentDisposition
        self.userInitiated = userInitiated
    }
}

public enum ResponseDecision: Equatable, Sendable {
    case allow
    /// Drop the response and do not tell the person. Used for subframe noise.
    case cancelSilently
    /// Save the body with `WKDownload`. Used for a main-frame attachment or a body WebKit cannot show.
    case download
}

/// External schemes are confirmed, except ones that would hand ssh-style options to another app.
public enum ExternalLaunchPolicy {
    private static let shellSchemes: Set<String> = ["ssh", "sftp", "scp", "telnet", "rlogin", "rsh"]
    private static let bannedFragments = [
        "proxycommand", "localcommand", "remotecommand", "permitlocalcommand"
    ]

    public static func allowsConfirmation(_ url: URL) -> Bool {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), host.hasPrefix("-") {
            return false
        }
        if let user = url.user?.trimmingCharacters(in: .whitespacesAndNewlines), user.hasPrefix("-") {
            return false
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if shellSchemes.contains(scheme) {
            if url.host?.isEmpty != false { return false }
            let raw = url.absoluteString.lowercased()
            let decoded = (url.absoluteString.removingPercentEncoding ?? url.absoluteString).lowercased()
            if bannedFragments.contains(where: { raw.contains($0) || decoded.contains($0) }) {
                return false
            }
            if shellPiecesLookLikeOptions(url) { return false }
        }
        return true
    }

    /// A shell handler may pass path, query, or userinfo through as argv. A token
    /// that starts with `-`, or a control character, is an option, not a hostname.
    private static func shellPiecesLookLikeOptions(_ url: URL) -> Bool {
        let pieces = [url.user, url.host, url.path, url.query, url.fragment].compactMap { $0 }
        for piece in pieces {
            let text = piece.removingPercentEncoding ?? piece
            if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                return true
            }
            let tokens = text.split { character in
                character == "/" || character == " " || character == "\t" || character == "&" || character == "?"
            }
            if tokens.contains(where: { $0.hasPrefix("-") }) { return true }
        }
        return false
    }

    /// Text for the confirm sheet. Directional overrides cannot hide the scheme.
    public static func promptText(for url: URL, maxLength: Int = 180) -> String {
        let cleaned = DirectionalText.strippingControls(url.absoluteString)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }

    /// Inspector links open only ordinary web URLs, and only those.
    public static func canOpenFromInspector(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

/// Limits confirm sheets a page can raise by navigating to external schemes.
public enum ExternalPromptGate {
    public static let maxPerWindow = 3
    public static let windowSeconds: TimeInterval = 10

    public static func allow(recent: [Date], now: Date) -> (allow: Bool, retained: [Date]) {
        let kept = recent.filter { now.timeIntervalSince($0) < windowSeconds }
        if kept.count >= maxPerWindow {
            return (false, kept)
        }
        return (true, kept + [now])
    }
}

public enum NavigationPolicy {
    public static func decide(_ request: NavigationRequest) -> NavigationDecision {
        guard let scheme = request.url.scheme?.lowercased(), !scheme.isEmpty else {
            return .cancel
        }
        switch scheme {
        case "http", "https", "about", "blob":
            return .allow
        case "javascript", "data":
            return .cancel
        case "wyvern":
            return InternalPage.parse(request.url) == nil ? .cancel : .allow
        case "file":
            return decideFile(request)
        case "icarus", "wyvern":
            // A page cannot start a terminal command. There is no run URL handler.
            return .cancel
        default:
            return ExternalLaunchPolicy.allowsConfirmation(request.url) ? .confirmExternal : .cancel
        }
    }

    /// 204 and 205 are allowed first. A subframe never starts a download. A main-frame
    /// attachment or a main-frame body WebKit cannot show becomes a download.
    public static func decideResponse(_ input: ResponseInput) -> ResponseDecision {
        if input.statusCode == 204 || input.statusCode == 205 {
            return .allow
        }
        let attachment = isAttachment(input.contentDisposition)
        if !input.isMainFrame {
            if attachment || !input.canShowMIMEType {
                return .cancelSilently
            }
            return .allow
        }
        if attachment || !input.canShowMIMEType {
            return .download
        }
        return .allow
    }

    /// The type token is the text before the first `;`, so parameters do not hide `attachment`.
    private static func isAttachment(_ header: String?) -> Bool {
        guard let header else { return false }
        let token = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }

    private static func decideFile(_ request: NavigationRequest) -> NavigationDecision {
        guard let typed = request.userTypedFileURL else {
            return .denyFile
        }
        // A website, or an about:blank frame inside one, must not keep the file
        // grant from a document the person opened earlier in this tab.
        if let current = request.currentPageURL {
            let scheme = current.scheme?.lowercased() ?? ""
            if scheme == "file" {
                let currentIsOpen = sameFile(current, typed) || isWithinDirectory(of: typed, candidate: current)
                if !currentIsOpen {
                    return .denyFile
                }
            } else if scheme != "about" && !scheme.isEmpty {
                return .denyFile
            } else if !sameFile(request.url, typed) {
                return .denyFile
            }
        }
        if sameFile(request.url, typed) {
            return .allow
        }
        // Subresources of a page the person typed may live beside that file.
        // A main-frame move to a different file is not allowed.
        if !request.isMainFrame, isWithinDirectory(of: typed, candidate: request.url) {
            return .allow
        }
        return .denyFile
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == "file", rhs.scheme?.lowercased() == "file" else {
            return false
        }
        return lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isWithinDirectory(of root: URL, candidate: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "file" else { return false }
        let rootDir = root.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        if rootDir == "/" {
            return path.hasPrefix("/")
        }
        return path == rootDir || path.hasPrefix(rootDir + "/")
    }
}
