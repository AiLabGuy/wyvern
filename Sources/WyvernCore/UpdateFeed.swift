// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum UpdateFeedError: Error, Equatable, Sendable {
    case tooLarge
    case malformed
    case unsupportedFormat
    case noUpdateListed
    case assetURLRejected
    /// The listed version or build differs from the zip name.
    case metadataMismatch
}

/// What a feed advertises. Untrusted until the downloaded zip verifies against it.
public struct UpdateCandidate: Equatable, Sendable {
    public var version: String
    public var build: Int
    /// Lowercase 40-hex commit, when the feed lists one. `latest.json` always does.
    public var commit: String?
    public var zipURL: URL
    public var zipName: UpdateZipName
    public var notes: String?

    public init(
        version: String,
        build: Int,
        commit: String?,
        zipURL: URL,
        zipName: UpdateZipName,
        notes: String? = nil
    ) {
        self.version = version
        self.build = build
        self.commit = commit
        self.zipURL = zipURL
        self.zipName = zipName
        self.notes = notes
    }
}

/// Reads a feed document. Two shapes are accepted at the source URL:
/// - a JSON object: the `latest.json` format in docs/UPDATES.md;
/// - a JSON array: Gitea issue comments whose attachments include the update zip.
public enum UpdateFeed {
    public static let formatVersion = 1
    public static let maxFeedBytes = 1024 * 1024
    public static let maxNotesLength = 2000

    public static func parse(
        _ data: Data,
        feedURL: URL,
        basename: String,
        allowsDevHTTP: Bool
    ) throws -> UpdateCandidate {
        guard data.count <= maxFeedBytes else { throw UpdateFeedError.tooLarge }
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UpdateFeedError.malformed
        }
        if top is [String: Any] {
            return try parseLatest(data, feedURL: feedURL, basename: basename, allowsDevHTTP: allowsDevHTTP)
        }
        if let comments = top as? [Any] {
            return try parseGiteaComments(comments, basename: basename, allowsDevHTTP: allowsDevHTTP)
        }
        throw UpdateFeedError.malformed
    }

    private struct LatestDocument: Decodable {
        var format: Int
        var version: String
        var build: Int
        var commit: String
        var zipURL: String
        var notes: String?

        enum CodingKeys: String, CodingKey {
            case format
            case version
            case build
            case commit
            case zipURL = "zip_url"
            case notes
        }
    }

    public static func parseLatest(
        _ data: Data,
        feedURL: URL,
        basename: String,
        allowsDevHTTP: Bool
    ) throws -> UpdateCandidate {
        let document: LatestDocument
        do {
            document = try JSONDecoder().decode(LatestDocument.self, from: data)
        } catch {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let format = object["format"] as? Int, format != formatVersion {
                throw UpdateFeedError.unsupportedFormat
            }
            throw UpdateFeedError.malformed
        }
        guard document.format == formatVersion else { throw UpdateFeedError.unsupportedFormat }
        guard UpdateVersion.isValidVersion(document.version),
              UpdateVersion.isValidBuild(String(document.build)),
              UpdateVersion.isValidCommit(document.commit) else {
            throw UpdateFeedError.malformed
        }
        // A relative zip_url resolves against the feed URL, so a fork can host both side by side.
        guard let resolved = URL(string: document.zipURL, relativeTo: feedURL)?.absoluteURL,
              case .success = UpdateTransportPolicy.checkURL(resolved, allowsDevHTTP: allowsDevHTTP),
              let zipName = UpdateZipName.parse(fileName: resolved.lastPathComponent, basename: basename) else {
            throw UpdateFeedError.assetURLRejected
        }
        guard zipName.version == document.version, zipName.build == document.build else {
            throw UpdateFeedError.metadataMismatch
        }
        return UpdateCandidate(
            version: document.version,
            build: document.build,
            commit: document.commit.lowercased(),
            zipURL: resolved,
            zipName: zipName,
            notes: document.notes.map { String($0.prefix(maxNotesLength)) }
        )
    }

    /// Newest `<basename>-<version>-b<build>.zip` attachment. The comment body may name the
    /// commit as `commit <40 hex>`; when it does, the signed commit must match it.
    public static func parseGiteaComments(
        _ comments: [Any],
        basename: String,
        allowsDevHTTP: Bool
    ) throws -> UpdateCandidate {
        var best: UpdateCandidate?
        for case let comment as [String: Any] in comments {
            guard let attachments = comment["attachments"] as? [[String: Any]] else { continue }
            let commit = commitHint(in: comment["body"] as? String)
            for item in attachments {
                let name = (item["name"] as? String) ?? ""
                let raw = (item["browser_download_url"] as? String) ?? (item["download_url"] as? String)
                guard let zipName = UpdateZipName.parse(fileName: name, basename: basename),
                      let raw, let url = URL(string: raw),
                      case .success = UpdateTransportPolicy.checkURL(url, allowsDevHTTP: allowsDevHTTP) else {
                    continue
                }
                let candidate = UpdateCandidate(
                    version: zipName.version,
                    build: zipName.build,
                    commit: commit,
                    zipURL: url,
                    zipName: zipName
                )
                if let current = best, !isOrderedBefore(current, candidate) {
                    continue
                }
                best = candidate
            }
        }
        guard let best else { throw UpdateFeedError.noUpdateListed }
        return best
    }

    /// Same order as `UpdateVersion.isNewer`: marketing version, then build.
    public static func isOrderedBefore(_ lhs: UpdateCandidate, _ rhs: UpdateCandidate) -> Bool {
        UpdateVersion.isNewer(
            remoteVersion: rhs.version,
            remoteBuild: String(rhs.build),
            localVersion: lhs.version,
            localBuild: String(lhs.build)
        )
    }

    public static func commitHint(in body: String?) -> String? {
        guard let body,
              let regex = try? NSRegularExpression(pattern: "\\bcommit ([0-9a-fA-F]{40})\\b"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return body[range].lowercased()
    }
}
