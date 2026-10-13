// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core
import CryptoKit
import Foundation

/// Fetches favicons with an ephemeral session. Redirects off the original host are refused.
/// The web view keeps its default user agent; this session does not copy or replace it.
@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private let session: URLSession
    private let redirectGuard = FaviconRedirectGuard()
    private var memory: [URL: NSImage] = [:]
    private var generation = 0
    private let directory: URL
    private let byteLimit = 1_000_000

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        directory = AppLocations.dataDirectory
            .appendingPathComponent(AppInfo.faviconCacheDirectoryName, isDirectory: true)
    }

    func image(for url: URL) async -> NSImage? {
        let generation = generation
        if let cached = memory[url] {
            return cached
        }
        if let stored = readDisk(url) {
            guard generation == self.generation else { return nil }
            memory[url] = stored
            return stored
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard generation == self.generation else { return nil }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard data.count <= byteLimit, let image = NSImage(data: data), image.isValid else {
                return nil
            }
            memory[url] = image
            writeDisk(url, data: data)
            return image
        } catch {
            return nil
        }
    }

    func clear() {
        generation += 1
        memory.removeAll()
        NotificationCenter.default.post(name: .app1FaviconsDidClear, object: self)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func readDisk(_ url: URL) -> NSImage? {
        let file = cacheFile(for: url)
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data), image.isValid else {
            return nil
        }
        return image
    }

    private func writeDisk(_ url: URL, data: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: url), options: [.atomic])
    }
}

extension Notification.Name {
    static let app1FaviconsDidClear = Notification.Name("\(AppInfo.bundleIdentifier).faviconsDidClear")
}

// Newer SDKs mark this completion Sendable. Match that so the optional method is used.
#if compiler(>=6)
typealias FaviconRedirectCompletion = @Sendable (URLRequest?) -> Void
#else
typealias FaviconRedirectCompletion = (URLRequest?) -> Void
#endif

/// Drops redirects that leave the host the icon was requested from.
final class FaviconRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping FaviconRedirectCompletion
    ) {
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let nextHost = request.url?.host?.lowercased()
        let scheme = request.url?.scheme?.lowercased()
        let schemeOK = scheme == "http" || scheme == "https"
        guard schemeOK, let originalHost, let nextHost, originalHost == nextHost else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
