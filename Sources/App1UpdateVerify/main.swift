// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import App1Core

/// CI check for a freshly built update zip. Shares `UpdatePackage` and `UpdateFeed` with the app.
///
///     App1UpdateVerify --zip Z --plist P [--require-newer] [--dev-http] [--feed latest.json --feed-url URL]
///
/// With `--feed`, the feed is parsed as the app would parse it from `--feed-url`, its zip name
/// must be the zip under test, and the signed version, build, and commit must match it.
@main
enum App1UpdateVerifyMain {
    static func main() {
        let args = CommandLine.arguments
        guard let zip = flag(args, "--zip"), let plistPath = flag(args, "--plist") else {
            refuse("usage")
        }
        let requireNewer = args.contains("--require-newer")
        guard let info = loadPlist(plistPath) else {
            refuse("plist")
        }
        let key = string(info, "App1UpdatePublicKey")
        let basename = string(info, "App1DMGBasename")
        let version = string(info, "CFBundleShortVersionString")
        let build = string(info, "CFBundleVersion")
        guard !key.isEmpty, !basename.isEmpty, !version.isEmpty, !build.isEmpty else {
            refuse("plist")
        }
        #if WYVERN_DEV_UPDATER
        let allowsDevHTTP = args.contains("--dev-http") || string(info, "App1UpdateDevSource") == "1"
        #else
        let allowsDevHTTP = false
        #endif
        var candidate: UpdateCandidate?
        if let feedPath = flag(args, "--feed") {
            guard let feedURLText = flag(args, "--feed-url"), let feedURL = URL(string: feedURLText),
                  let data = FileManager.default.contents(atPath: feedPath) else {
                refuse("usage")
            }
            do {
                candidate = try UpdateFeed.parse(
                    data,
                    feedURL: feedURL,
                    basename: basename,
                    allowsDevHTTP: allowsDevHTTP
                )
            } catch {
                refuse(token(for: error))
            }
        }
        do {
            let verified = try UpdatePackage.verifyZip(
                at: URL(fileURLWithPath: zip),
                encodedPublicKey: key,
                basename: basename,
                localVersion: requireNewer ? version : nil,
                localBuild: requireNewer ? build : nil,
                candidate: candidate
            )
            try? FileManager.default.removeItem(at: verified.directory)
            print("UPDATE_VERIFY_OK")
            fflush(stdout)
        } catch {
            refuse(token(for: error))
        }
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
        return value
    }

    private static func loadPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any] else {
            return nil
        }
        return info
    }

    private static func string(_ info: [String: Any], _ key: String) -> String {
        (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func token(for error: Error) -> String {
        if let package = error as? UpdatePackageError {
            switch package {
            case .tooLarge: return "too-large"
            case .badZipName: return "bad-zip-name"
            case .extractFailed: return "extract"
            case .zipMalformed: return "zip-malformed"
            case .unsupportedEntry: return "unsupported-entry"
            case .pathTraversal: return "path-traversal"
            case .duplicateEntry: return "duplicate-entry"
            case .unexpectedEntry: return "unexpected-entry"
            case .symlinkRejected: return "symlink"
            case .notRegularFile: return "not-regular"
            case .missingMember: return "missing-member"
            case .checksumNameMismatch: return "checksum-name"
            case .checksumMismatch: return "checksum"
            case .commentRejected: return "comment"
            case .commentFileMismatch: return "comment-file"
            case .zipNameMismatch: return "zip-name"
            case .metadataMismatch: return "metadata"
            case .notNewer: return "not-newer"
            }
        }
        if let feed = error as? UpdateFeedError {
            switch feed {
            case .tooLarge: return "feed-too-large"
            case .malformed: return "feed-malformed"
            case .unsupportedFormat: return "feed-format"
            case .noUpdateListed: return "feed-empty"
            case .assetURLRejected: return "feed-asset-url"
            case .metadataMismatch: return "feed-metadata"
            }
        }
        if let sign = error as? MinisignError {
            if case .prehashedRefused = sign {
                return "prehashed"
            }
            return "signature"
        }
        return "refused"
    }

    private static func refuse(_ token: String) -> Never {
        fputs("UPDATE_VERIFY_REFUSED \(token)\n", stderr)
        print("UPDATE_VERIFY_REFUSED \(token)")
        fflush(stdout)
        exit(1)
    }
}
