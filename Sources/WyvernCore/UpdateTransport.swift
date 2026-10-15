// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Redirects during an update check or download. Integrity comes from the signature,
/// so an HTTPS redirect may change host (release assets often live on a CDN host).
/// HTTPS never downgrades to HTTP. Dev HTTP stays on the same private host.
public enum UpdateRedirectPolicy {
    public static func shouldFollow(from: URL, to: URL?, allowsDevHTTP: Bool) -> Bool {
        guard let to else { return false }
        guard case .success(let destination) = UpdateTransportPolicy.checkURL(to, allowsDevHTTP: allowsDevHTTP) else {
            return false
        }
        let toHost = destination.host?.lowercased() ?? ""
        let fromHost = from.host?.lowercased() ?? ""
        if destination.scheme?.lowercased() == "http" {
            guard from.scheme?.lowercased() == "http", fromHost == toHost else { return false }
        }
        // A public source may redirect to a public CDN. It may not redirect onto the LAN.
        if !allowsDevHTTP, NetworkHostPolicy.isNonPublic(toHost), toHost != fromHost {
            return false
        }
        return true
    }
}

/// Plain-language text for every refusal the updater can hit.
public enum UpdateUserMessage {
    public static func text(for error: Error) -> String {
        if let error = error as? UpdateSourceError {
            return text(for: error)
        }
        if let error = error as? UpdateFeedError {
            switch error {
            case .tooLarge, .malformed:
                return "The update source did not return a valid update list."
            case .unsupportedFormat:
                return "The update source uses a newer list format than this version understands."
            case .noUpdateListed:
                return "The update source does not list any update for this app."
            case .assetURLRejected:
                return "The update source lists a download address that is not allowed. Downloads must use HTTPS."
            case .metadataMismatch:
                return "The update source lists inconsistent version details. Nothing was installed."
            }
        }
        if let error = error as? MinisignError {
            switch error {
            case .emptyKey, .malformed:
                return "The update's signature is missing or unreadable. Nothing was installed."
            case .wrongKeyID:
                return "The update was signed with a different key than the one set for this source. Nothing was installed."
            case .invalidSignature, .prehashedRefused:
                return "The update's signature is not valid. It may have been altered. Nothing was installed."
            }
        }
        if let error = error as? UpdatePackageError {
            switch error {
            case .tooLarge:
                return "The download is empty or larger than allowed. Nothing was installed."
            case .badZipName, .zipNameMismatch, .metadataMismatch, .commentRejected, .commentFileMismatch:
                return "The signed update does not match the release the source described. Nothing was installed."
            case .notNewer:
                return "The signed update is not newer than this version. Nothing was installed."
            case .checksumMismatch, .checksumNameMismatch:
                return "The downloaded disk image does not match its signed checksum. Nothing was installed."
            case .extractFailed, .zipMalformed, .unsupportedEntry, .pathTraversal, .duplicateEntry,
                 .unexpectedEntry, .symlinkRejected, .notRegularFile, .missingMember:
                return "The downloaded update package is not in the expected form. Nothing was installed."
            }
        }
        if let error = error as? AtomicInstallError {
            switch error {
            case .notInstalledAsApp:
                return "This copy is not running from an app bundle, so it cannot update itself."
            case .translocated:
                return "macOS is running this app from a temporary location. Move it to the Applications folder, open it from there, and try again."
            case .notWritable:
                return "The folder that holds the app is not writable. Move the app to a folder you can write to, or update by hand."
            case .appNotFound:
                return "The disk image does not contain the app. Nothing was installed."
            case .codesignFailed, .bundleMismatch, .unsignedRefused, .checksumMismatch:
                return "The new app failed its code signature check. The installed app was left unchanged."
            case .moveFailed, .mountFailed:
                return "The update could not be installed. The installed app was left unchanged."
            case .restoreFailed:
                return "The update failed and the previous app could not be put back automatically. Look for a backup copy next to the app."
            }
        }
        return "The update failed. The installed app was left unchanged."
    }

    public static func text(for error: UpdateSourceError) -> String {
        switch error {
        case .notConfigured:
            return "This build has no update source. Set one in Settings > Updates."
        case .emptyURL:
            return "Enter the address of an update source."
        case .malformedURL:
            return "The update source address is not a valid web address."
        case .credentialsInURL:
            return "The update source address must not contain a user name or password."
        case .httpRejected, .publicHTTPRejected:
            return "The update source must use HTTPS."
        case .restrictedHost:
            return "The update address must be public HTTPS, or the same host as the update source. Addresses on this computer are not allowed."
        case .missingKey:
            return "Enter the public key for this update source. A source is never used without its key."
        case .malformedKey:
            return "The public key is not valid. Paste the minisign public key line that starts with RWQ."
        }
    }
}
