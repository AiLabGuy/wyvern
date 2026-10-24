// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Plain-language copy for a failed page load, plus a small HTML error document.
public struct LoadFailureCopy: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// When true, the UI may skip showing a page (e.g. a benign cancel with no URL).
    public var preferSilent: Bool

    public init(title: String, detail: String, preferSilent: Bool = false) {
        self.title = title
        self.detail = detail
        self.preferSilent = preferSilent
    }

    public static func from(error: Error) -> LoadFailureCopy {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return from(urlErrorCode: ns.code, localized: ns.localizedDescription)
        }
        if let urlError = error as? URLError {
            return from(urlErrorCode: urlError.errorCode, localized: urlError.localizedDescription)
        }
        return LoadFailureCopy(
            title: "This page can’t be loaded",
            detail: sanitize(ns.localizedDescription)
        )
    }

    public static func from(urlErrorCode code: Int, localized: String) -> LoadFailureCopy {
        switch code {
        case NSURLErrorNotConnectedToInternet:
            return LoadFailureCopy(
                title: "You’re offline",
                detail: "Check your network connection and try again."
            )
        case NSURLErrorNetworkConnectionLost:
            return LoadFailureCopy(
                title: "Connection lost",
                detail: "The network connection was interrupted. Try again."
            )
        case NSURLErrorTimedOut:
            return LoadFailureCopy(
                title: "This page took too long",
                detail: "The server did not respond in time. Try again."
            )
        case NSURLErrorCannotFindHost:
            return LoadFailureCopy(
                title: "Server not found",
                detail: "\(AppInfo.displayName) couldn’t find that server. Check the address and try again."
            )
        case NSURLErrorDNSLookupFailed:
            return LoadFailureCopy(
                title: "Server not found",
                detail: "The address could not be resolved. Check the spelling and try again."
            )
        case NSURLErrorCannotConnectToHost:
            return LoadFailureCopy(
                title: "Couldn’t connect",
                detail: "The server refused the connection or isn’t reachable right now."
            )
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorCannotLoadFromNetwork:
            return LoadFailureCopy(
                title: "Connection not private",
                detail: "\(AppInfo.displayName) couldn’t establish a secure connection to this site."
            )
        case NSURLErrorCancelled:
            return LoadFailureCopy(
                title: "Load cancelled",
                detail: "The page stopped loading.",
                preferSilent: false
            )
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return LoadFailureCopy(
                title: "Invalid address",
                detail: "That address isn’t something \(AppInfo.displayName) can open."
            )
        case NSURLErrorDataNotAllowed:
            return LoadFailureCopy(
                title: "Network not allowed",
                detail: "This device isn’t allowed to use the network right now."
            )
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return LoadFailureCopy(
                title: "Secure connection required",
                detail: "This address must use HTTPS."
            )
        default:
            let cleaned = sanitize(localized)
            return LoadFailureCopy(
                title: "This page can’t be loaded",
                detail: cleaned.isEmpty ? "Something went wrong while loading this page." : cleaned
            )
        }
    }

    /// Escape text for inclusion in an HTML document.
    public static func escapeHTML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    public static func failingURL(from error: Error) -> URL? {
        let ns = error as NSError
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return url
        }
        if let string = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           let url = URL(string: string) {
            return url
        }
        if let string = ns.userInfo["NSErrorFailingURLStringKey"] as? String,
           let url = URL(string: string) {
            return url
        }
        return nil
    }

    /// Minimal dark error document with title, detail, URL, and Reload link.
    public static func htmlDocument(copy: LoadFailureCopy, failingURL: URL?) -> String {
        let title = escapeHTML(copy.title)
        let detail = escapeHTML(copy.detail)
        let urlText = failingURL.map { escapeHTML($0.absoluteString) } ?? ""
        let reloadHref: String
        if let failingURL {
            reloadHref = escapeHTML(failingURL.absoluteString)
        } else {
            reloadHref = ""
        }
        let urlBlock: String
        if urlText.isEmpty {
            urlBlock = ""
        } else {
            urlBlock = "<p class=\"url\">\(urlText)</p>"
        }
        let reloadBlock: String
        if reloadHref.isEmpty {
            reloadBlock = ""
        } else {
            reloadBlock = "<p><a class=\"reload\" href=\"\(reloadHref)\">Reload</a></p>"
        }
        let name = escapeHTML(AppInfo.displayName)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: dark light; }
          body {
            margin: 0; padding: 48px 24px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #1c1c1e; color: #f2f2f7;
          }
          @media (prefers-color-scheme: light) {
            body { background: #f5f5f7; color: #1c1c1e; }
            .url { color: #6e6e73; }
            .reload { background: #007aff; }
          }
          main { max-width: 36rem; margin: 0 auto; }
          h1 { font-size: 1.5rem; font-weight: 600; margin: 0 0 0.75rem; }
          p { font-size: 0.95rem; line-height: 1.45; margin: 0 0 1rem; opacity: 0.9; }
          .url {
            font-family: ui-monospace, Menlo, monospace; font-size: 0.85rem;
            word-break: break-all; color: #8e8e93; opacity: 1;
          }
          .reload {
            display: inline-block; padding: 0.55rem 1rem; border-radius: 8px;
            background: #0a84ff; color: #fff; text-decoration: none; font-weight: 500;
          }
          .foot { margin-top: 2rem; font-size: 0.8rem; opacity: 0.55; }
        </style>
        </head>
        <body>
        <main>
          <h1>\(title)</h1>
          <p>\(detail)</p>
          \(urlBlock)
          \(reloadBlock)
          <p class="foot">\(name)</p>
        </main>
        </body>
        </html>
        """
    }

    private static func sanitize(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "\u{202E}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count > 280 {
            return String(stripped.prefix(279)) + "…"
        }
        return stripped
    }
}
