// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security
import App1Core
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Signs update checksums. The private seed lives in a 0600 key file outside the workspace
/// (`UPDATE_SIGNING_KEY_FILE`, default `~/Library/Application Support/WyvernBuild/update-signing.key`).
/// CI reads only that file, so it never waits on a keychain prompt. The keychain is read only
/// with `--keychain`, during the one-time migration in `--ensure`, or by `--export-from-keychain`.
/// This tool never generates a key: the public key embedded in the app must not rotate silently.
@main
enum App1UpdateSignerMain {
    private static let serviceName = "app1-update-signing"
    private static let accountName = "ci"
    private static let seedLength = 32
    /// Must equal `UPDATE_PUBLIC_KEY` in config/product.env (and so Resources/Info.plist).
    /// Seeds whose public key differs are refused.
    private static let embeddedPublicKey = "RELEASE_PUBLIC_KEY_PLACEHOLDER"
    /// Below the CI step's 60 s alarm, so this tool's own UPDATE_KEY_MISSING line prints first.
    private static let ciKeychainTimeout: TimeInterval = 45
    /// A manual export may wait for someone to answer the keychain dialog.
    private static let manualKeychainTimeout: TimeInterval = 120

    private static let usage = """
    usage: App1UpdateSigner --ensure [--keychain]
           App1UpdateSigner --sign FILE.sha256 --version V --build N --commit SHA --file DMG [--keychain]
           App1UpdateSigner --export-from-keychain

    """

    static func main() {
        let args = CommandLine.arguments
        let useKeychain = args.contains("--keychain")
        if args.contains("--create-and-store") {
            fail("UPDATE_KEY_REFUSED", "this tool never generates a signing key; the embedded public key must not rotate")
        }
        if args.contains("--export-from-keychain") {
            exportFromKeychain()
            return
        }
        if args.contains("--ensure") {
            ensureMaterial(useKeychain: useKeychain)
            return
        }
        if let idx = args.firstIndex(of: "--sign"), idx + 1 < args.count {
            sign(path: args[idx + 1], args: args, useKeychain: useKeychain)
            return
        }
        fputs(usage, stderr)
        exit(1)
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
        return value
    }

    private static func fail(_ code: String, _ message: String) -> Never {
        fputs("error: \(code): \(message)\n", stderr)
        exit(1)
    }

    /// Stdout is `UPDATE_PUBLIC_KEY=...`, preceded by `UPDATE_KEY_MIGRATED` on the one run
    /// that copies the keychain item into the key file.
    private static func ensureMaterial(useKeychain: Bool) {
        if useKeychain {
            let signer = verified(keychainSeed(timeout: ciKeychainTimeout, allowUI: false))
            emitPublicLine(signer)
            return
        }
        let url = keyFileURL()
        if keyFileExists(url) {
            emitPublicLine(verified(readKeyFile(url)))
            return
        }
        // Never touch the keychain unattended: on the legacy login keychain an ACL check shows a
        // SecurityAgent dialog even without UI allowed, and that dialog stays on screen and steals
        // focus from the GUI tests. Migration is manual only (--export-from-keychain).
        fail("UPDATE_KEY_MISSING", "no key file at \(display(url.path)); run App1UpdateSigner --export-from-keychain once from a logged-in Terminal")
    }

    /// Manual, from a logged-in Terminal: the keychain may show its dialog. Never overwrites.
    private static func exportFromKeychain() {
        let url = keyFileURL()
        if keyFileExists(url) {
            fail("UPDATE_KEY_FILE_EXISTS", "\(display(url.path)) already exists; it is not overwritten")
        }
        let seed = keychainSeed(timeout: manualKeychainTimeout, allowUI: true)
        let signer = verified(seed)
        writeKeyFile(seed, to: url)
        print("UPDATE_KEY_MIGRATED")
        emitPublicLine(signer)
    }

    private static func sign(path: String, args: [String], useKeychain: Bool) {
        guard let version = flag(args, "--version"),
              let build = flag(args, "--build"),
              let commit = flag(args, "--commit"),
              let file = flag(args, "--file"),
              let comment = TrustedUpdateComment.parse(
                "wyvern version=\(version) build=\(build) commit=\(commit) file=\(file)"
              ) else {
            fputs("sign requires --version --build --commit --file\n", stderr)
            exit(1)
        }
        let seed: Data
        if useKeychain {
            seed = keychainSeed(timeout: ciKeychainTimeout, allowUI: false)
        } else {
            let url = keyFileURL()
            guard keyFileExists(url) else {
                fail("UPDATE_KEY_MISSING", "no key file at \(display(url.path)); run App1UpdateSigner --ensure")
            }
            seed = readKeyFile(url)
        }
        let signer = verified(seed)
        guard let message = FileManager.default.contents(atPath: path) else {
            fputs("missing sha256 file\n", stderr)
            exit(1)
        }
        do {
            // Legacy "Ed". Stock minisign needs -l to produce the same algorithm byte.
            let text = try Minisign.signedText(
                message: message,
                signer: signer,
                comment: comment.line
            )
            let dest = path + ".minisig"
            try text.write(toFile: dest, atomically: true, encoding: .utf8)
        } catch {
            fputs("sign failed\n", stderr)
            exit(1)
        }
    }

    /// The seed's public key must be the embedded one. A different key is never used or stored.
    private static func verified(_ seed: Data) -> Curve25519.Signing.PrivateKey {
        let signer: Curve25519.Signing.PrivateKey
        do {
            signer = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            fail("UPDATE_KEY_MALFORMED", "signing material is not a 32-byte Ed25519 seed")
        }
        let encoded = Minisign.encodePublicKey(raw: signer.publicKey.rawRepresentation)
        guard encoded == embeddedPublicKey else {
            fail("UPDATE_KEY_MISMATCH", "signing key does not match the embedded public key \(embeddedPublicKey)")
        }
        return signer
    }

    private static func emitPublicLine(_ signer: Curve25519.Signing.PrivateKey) {
        print("UPDATE_PUBLIC_KEY=\(Minisign.encodePublicKey(raw: signer.publicKey.rawRepresentation))")
        fflush(stdout)
    }

    // MARK: - Key file

    /// `UPDATE_SIGNING_KEY_FILE`, else `~/Library/Application Support/WyvernBuild/update-signing.key`.
    /// A path inside the checkout is refused, so the seed cannot be committed or uploaded.
    private static func keyFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let url: URL
        if let raw = env["UPDATE_SIGNING_KEY_FILE"], !raw.isEmpty {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("WyvernBuild", isDirectory: true)
                .appendingPathComponent("update-signing.key")
        }
        // The CI workspace, and the current directory when it is a checkout (has Package.swift).
        var roots: [String] = []
        if let workspace = env["GITHUB_WORKSPACE"], !workspace.isEmpty {
            roots.append(workspace)
        }
        let cwd = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent("Package.swift")) {
            roots.append(cwd)
        }
        let path = url.resolvingSymlinksInPath().path
        for root in roots {
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            if path == base || path.hasPrefix(base + "/") {
                fail("UPDATE_KEY_IN_WORKSPACE", "the key file must live outside the checkout")
            }
        }
        return url
    }

    private static func keyFileExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }

    /// Regular file, owned by this user, mode exactly 0600, in a real directory this user owns
    /// with no group or other access. Opened with O_NOFOLLOW and re-checked on the open descriptor.
    private static func readKeyFile(_ url: URL) -> Data {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            fail("UPDATE_KEY_MISSING", "cannot stat \(display(url.path))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            fail("UPDATE_KEY_INSECURE", "\(display(url.path)) is not a regular file")
        }
        guard info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o600 else {
            fail("UPDATE_KEY_INSECURE", "\(display(url.path)) must be owned by this user with mode 0600")
        }
        var dirInfo = stat()
        let dir = url.deletingLastPathComponent().path
        // lstat refuses a symlink directory. 0o077 == 0 rejects any group or other permission bit.
        guard dir.withCString({ lstat($0, &dirInfo) }) == 0,
              (dirInfo.st_mode & S_IFMT) == S_IFDIR,
              dirInfo.st_uid == getuid(),
              (dirInfo.st_mode & 0o077) == 0 else {
            fail("UPDATE_KEY_INSECURE", "\(display(dir)) must be a directory owned by this user with no group or other access")
        }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else {
            fail("UPDATE_KEY_INSECURE", "cannot open \(display(url.path)) without following links")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              opened.st_uid == getuid(),
              (opened.st_mode & S_IFMT) == S_IFREG,
              (opened.st_mode & 0o7777) == 0o600 else {
            fail("UPDATE_KEY_INSECURE", "\(display(url.path)) changed while it was being read")
        }
        guard let data = try? handle.readToEnd(), let seed = decodeSeed(data) else {
            fail("UPDATE_KEY_MALFORMED", "\(display(url.path)) does not hold a base64 32-byte seed")
        }
        return seed
    }

    /// Directory 0700; file created with `open(O_CREAT|O_EXCL|O_NOFOLLOW, 0600)` then `fchmod` 0600,
    /// so an existing file is never replaced and umask cannot leave a mode other than 0600.
    private static func writeKeyFile(_ seed: Data, to url: URL) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            fail("UPDATE_KEY_WRITE", "cannot create \(display(dir.path))")
        }
        guard dir.path.withCString({ chmod($0, 0o700) }) == 0 else {
            fail("UPDATE_KEY_WRITE", "cannot set mode 0700 on \(display(dir.path))")
        }
        let path = url.path
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600)) }
        if fd < 0 {
            if errno == EEXIST {
                fail("UPDATE_KEY_FILE_EXISTS", "\(display(path)) already exists; it is not overwritten")
            }
            fail("UPDATE_KEY_WRITE", "cannot create \(display(path))")
        }
        if fchmod(fd, mode_t(0o600)) != 0 {
            close(fd)
            _ = path.withCString { unlink($0) }
            fail("UPDATE_KEY_WRITE", "cannot set mode 0600 on \(display(path))")
        }
        let encoded = Data((seed.base64EncodedString() + "\n").utf8)
        let written = encoded.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, buffer.count)
        }
        let synced = fsync(fd) == 0
        close(fd)
        if written != encoded.count || !synced {
            _ = path.withCString { unlink($0) }
            fail("UPDATE_KEY_WRITE", "short write to \(display(path)); file removed")
        }
    }

    private static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard home.count > 1, path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    // MARK: - Keychain (migration and explicit --keychain only)

    private enum ChainResult {
        case present(Data)
        case missing
        case unavailable(OSStatus)
    }

    private final class ChainBox: @unchecked Sendable {
        var result: ChainResult = .missing
    }

    /// One keychain read on a worker thread. If it does not return within `timeout` (a dialog
    /// is waiting), fail loudly; exiting ends the blocked thread with the process.
    private static func keychainSeed(timeout: TimeInterval, allowUI: Bool) -> Data {
        let box = ChainBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Self.readKeychain(allowUI: allowUI)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            fail(
                "UPDATE_KEY_MISSING",
                "keychain read did not finish in \(Int(timeout)) s; run App1UpdateSigner --export-from-keychain once from a logged-in Terminal"
            )
        }
        switch box.result {
        case .present(let seed):
            return seed
        case .missing:
            fail("UPDATE_KEY_MISSING", "no key file and no keychain item \(serviceName); see SECURITY.md")
        case .unavailable(let status):
            fail(
                "UPDATE_KEY_MISSING",
                "keychain item unreadable (status \(status)); run App1UpdateSigner --export-from-keychain once from a logged-in Terminal"
            )
        }
    }

    private static func readKeychain(allowUI: Bool) -> ChainResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, let seed = decodeSeed(data) else {
                return .unavailable(status)
            }
            return .present(seed)
        }
        if status == errSecItemNotFound {
            return .missing
        }
        return .unavailable(status)
    }

    private static func decodeSeed(_ data: Data) -> Data? {
        if data.count == seedLength {
            return data
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let decoded = Data(base64Encoded: text), decoded.count == seedLength {
            return decoded
        }
        return nil
    }
}
