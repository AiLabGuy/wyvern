// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore
import Foundation

/// One HTTP GET into a new 0600 file, with a byte cap, the update redirect policy, and cancel.
/// Delegate callbacks run on a private serial queue; the session is invalidated on completion.
final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        case finished(Int64)
        case failed(String)
        case cancelled
    }

    private let destination: URL
    private let maxBytes: Int64
    private let allowsDevHTTP: Bool
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let queue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var lastReported: Int64 = 0
    private var failure: String?
    private var wasCancelled = false
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(
        destination: URL,
        maxBytes: Int64,
        allowsDevHTTP: Bool,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.allowsDevHTTP = allowsDevHTTP
        self.onProgress = onProgress
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func run(_ url: URL, timeout: TimeInterval) async -> Outcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let prepared = request
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                self.continuation = continuation
                self.session = session
                if self.wasCancelled {
                    self.complete(.cancelled)
                    return
                }
                let task = session.dataTask(with: prepared)
                self.task = task
                task.resume()
            }
        }
    }

    func cancel() {
        queue.addOperation {
            self.wasCancelled = true
            self.task?.cancel()
        }
    }

    private func complete(_ outcome: Outcome) {
        try? handle?.close()
        handle = nil
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            failure = failure ?? "HTTP status \(code)"
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > maxBytes {
            failure = "declared size over the cap"
            completionHandler(.cancel)
            return
        }
        expected = http.expectedContentLength
        let fd = destination.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600)) }
        guard fd >= 0 else {
            failure = "could not create the download file"
            completionHandler(.cancel)
            return
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        received += Int64(data.count)
        if received > maxBytes {
            failure = "size over the cap"
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = "could not write the download file"
            dataTask.cancel()
            return
        }
        if received - lastReported >= 512 * 1024 {
            lastReported = received
            onProgress(received, expected)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let from = response.url ?? task.currentRequest?.url,
              UpdateRedirectPolicy.shouldFollow(from: from, to: request.url, allowsDevHTTP: allowsDevHTTP) else {
            failure = "redirect refused"
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if wasCancelled {
            complete(.cancelled)
        } else if let failure {
            complete(.failed(failure))
        } else if let error {
            complete(.failed("network error \((error as NSError).code)"))
        } else if received == 0 {
            complete(.failed("empty response"))
        } else {
            complete(.finished(received))
        }
    }
}

/// Check, offer, then download, verify, install, and relaunch. Nothing installs without
/// a second click, and nothing installs without a valid signature from the source's key.
@MainActor
final class AppUpdater {
    let sourceStore: UpdateSourceStore
    private let settings: SettingsStore
    private let logURL: URL
    private var sheet: UpdateSheetController?
    private var activeDownload: UpdateDownload?
    private var pending: (candidate: UpdateCandidate, source: UpdateSource)?
    private var cancelled = false
    private var busy = false

    init(settings: SettingsStore) {
        self.settings = settings
        sourceStore = UpdateSourceStore(
            defaults: AppLocations.userDefaults,
            info: Bundle.main.infoDictionary ?? [:]
        )
        let dir = AppLocations.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("update.log")
    }

    /// Check for Updates… menu item and Settings button.
    func start(from window: NSWindow?) {
        if let sheetWindow = sheet?.window, sheetWindow.isVisible {
            sheetWindow.makeKeyAndOrderFront(nil)
            return
        }
        cancelled = false
        pending = nil
        let controller = UpdateSheetController()
        sheet = controller
        controller.onCancel = { [weak self] in
            self?.cancel()
        }
        controller.onInstall = { [weak self] in
            self?.installPending()
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.sheet === controller else { return }
            self.sheet = nil
        }
        if let window, let sheetWindow = controller.window {
            window.beginSheet(sheetWindow)
        } else {
            controller.window?.center()
            controller.showWindow(nil)
        }
        controller.showChecking()
        busy = true
        Task {
            await self.check()
            self.busy = false
        }
    }

    private func cancel() {
        cancelled = true
        pending = nil
        activeDownload?.cancel()
    }

    private func check() async {
        appendLog("check start; running \(AppInfo.shortVersion) build \(AppInfo.bundleVersion)")
        let source: UpdateSource
        switch sourceStore.current() {
        case .failure(let error):
            finish(false, message: UpdateUserMessage.text(for: error))
            return
        case .success(let value):
            source = value
        }
        appendLog("source \(source.origin.rawValue) host \(source.feedURL.host ?? "?") key \(source.keyFingerprint)")
        let scratch: URL
        do {
            scratch = try makeScratch()
        } catch {
            finish(false, message: "Could not create a temporary folder for the update check.")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let feedFile = scratch.appendingPathComponent("feed.json")
        let outcome = await download(
            source.feedURL,
            to: feedFile,
            maxBytes: Int64(UpdateFeed.maxFeedBytes),
            allowsDevHTTP: source.allowsDevHTTP,
            timeout: 30,
            showsProgress: false
        )
        if cancelled { return }
        guard case .finished = outcome, let data = try? Data(contentsOf: feedFile) else {
            if case .failed(let reason) = outcome {
                appendLog("feed fetch failed: \(reason)")
            }
            finish(false, message: "Could not reach the update source. Check your connection, or the source address in Settings > Updates.")
            return
        }
        let candidate: UpdateCandidate
        do {
            candidate = try UpdateFeed.parse(
                data,
                feedURL: source.feedURL,
                basename: AppInfo.dmgBasename,
                allowsDevHTTP: source.allowsDevHTTP
            )
        } catch {
            appendLog("feed refused: \(error)")
            finish(false, message: UpdateUserMessage.text(for: error))
            return
        }
        appendLog("feed lists \(candidate.version) build \(candidate.build) commit \(candidate.commit ?? "unlisted")")
        guard UpdateVersion.isNewer(
            remoteVersion: candidate.version,
            remoteBuild: String(candidate.build),
            localVersion: AppInfo.shortVersion,
            localBuild: AppInfo.bundleVersion
        ) else {
            finish(true, message: "You're up to date. Version \(AppInfo.shortVersion) (build \(AppInfo.bundleVersion)) is the newest available.")
            return
        }
        pending = (candidate, source)
        sheet?.showAvailable(headline: "Version \(candidate.version) (build \(candidate.build)) is available.", details: offerDetails(candidate, source: source))
    }

    private func offerDetails(_ candidate: UpdateCandidate, source: UpdateSource) -> String {
        var lines = [
            "You have version \(AppInfo.shortVersion) (build \(AppInfo.bundleVersion)).",
            "Commit: \(candidate.commit ?? "not listed; read from the signature after download")",
            "Source: \(source.feedURL.host ?? "") · key ID \(source.keyFingerprint)"
        ]
        if let notes = candidate.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append(String(notes.prefix(400)))
        }
        return lines.joined(separator: "\n")
    }

    private func installPending() {
        guard let pending, !busy else { return }
        busy = true
        cancelled = false
        Task {
            let installed = await self.install(pending.candidate, source: pending.source)
            self.busy = false
            self.pending = nil
            if installed {
                self.relaunch()
            }
        }
    }

    /// True when the new app is in place. All temporary files are gone when this returns.
    private func install(_ candidate: UpdateCandidate, source: UpdateSource) async -> Bool {
        appendLog("install \(candidate.version) build \(candidate.build)")
        let installed = Bundle.main.bundleURL
        if let problem = Self.installLocationProblem(installed) {
            appendLog("install location refused: \(problem)")
            finish(false, message: UpdateUserMessage.text(for: problem))
            return false
        }
        let scratch: URL
        do {
            scratch = try makeScratch()
        } catch {
            finish(false, message: "Could not create a temporary folder for the update.")
            return false
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        sheet?.setStep(.download, detail: candidate.zipName.fileName)
        let zipFile = scratch.appendingPathComponent(candidate.zipName.fileName)
        let outcome = await download(
            candidate.zipURL,
            to: zipFile,
            maxBytes: UpdatePackage.maxZipBytes,
            allowsDevHTTP: source.allowsDevHTTP,
            timeout: 120,
            showsProgress: true
        )
        switch outcome {
        case .cancelled:
            finish(false, message: "Update cancelled. Nothing was changed.")
            return false
        case .failed(let reason):
            appendLog("download failed: \(reason)")
            finish(false, message: "The download did not finish. Nothing was changed.")
            return false
        case .finished(let bytes):
            appendLog("downloaded \(bytes) bytes")
        }
        if cancelled {
            finish(false, message: "Update cancelled. Nothing was changed.")
            return false
        }

        sheet?.setStep(.verify, detail: "Checking the signature and checksum")
        let key = source.publicKey.encoded
        let basename = AppInfo.dmgBasename
        let localVersion = AppInfo.shortVersion
        let localBuild = AppInfo.bundleVersion
        let verified: VerifiedZip
        do {
            verified = try await Task.detached(priority: .userInitiated) {
                try UpdatePackage.verifyZip(
                    at: zipFile,
                    encodedPublicKey: key,
                    basename: basename,
                    localVersion: localVersion,
                    localBuild: localBuild,
                    candidate: candidate
                )
            }.value
        } catch {
            appendLog("verify refused: \(error)")
            finish(false, message: UpdateUserMessage.text(for: error))
            return false
        }
        defer { try? FileManager.default.removeItem(at: verified.directory) }
        appendLog("verified \(verified.comment.version) build \(verified.comment.build) commit \(verified.comment.commit)")
        if cancelled {
            finish(false, message: "Update cancelled. Nothing was changed.")
            return false
        }

        sheet?.setStep(.install, detail: "Installing version \(verified.comment.version)")
        let bundleID = AppInfo.bundleIdentifier
        let dmg = verified.dmgURL
        do {
            let backup = try await Task.detached(priority: .userInitiated) {
                try AppUpdater.installFromDiskImage(dmg, scratch: scratch, installed: installed, bundleID: bundleID)
            }.value
            settings.update { $0.pendingUpdateBackupPath = backup.path }
        } catch {
            appendLog("install failed: \(error)")
            finish(false, message: UpdateUserMessage.text(for: error))
            return false
        }
        appendLog("installed \(verified.comment.version) build \(verified.comment.build)")
        finish(true, message: "Updated to version \(verified.comment.version). Relaunching…")
        return true
    }

    private static func installLocationProblem(_ installed: URL) -> AtomicInstallError? {
        if installed.pathExtension != "app" {
            return .notInstalledAsApp
        }
        if installed.path.contains("/AppTranslocation/") {
            return .translocated
        }
        if !FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) {
            return .notWritable
        }
        return nil
    }

    /// Mounts the verified image read-only, copies its single `.app` beside the installed app
    /// (same volume, so the swap is a rename), then swaps with codesign checks and rollback.
    nonisolated static func installFromDiskImage(
        _ dmg: URL,
        scratch: URL,
        installed: URL,
        bundleID: String
    ) throws -> URL {
        let mount = scratch.appendingPathComponent("mnt", isDirectory: true)
        try UpdatePackage.createPrivateDirectory(mount)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            throw AtomicInstallError.mountFailed
        }
        defer {
            if !run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) {
                run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
        }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let found = apps.first, isPlainDirectory(found) else {
            throw AtomicInstallError.appNotFound
        }
        let parent = installed.deletingLastPathComponent()
        let stem = installed.deletingPathExtension().lastPathComponent
        let staged = parent.appendingPathComponent(".\(stem).update-\(UUID().uuidString).app", isDirectory: true)
        guard run("/usr/bin/ditto", [found.path, staged.path]) else {
            try? FileManager.default.removeItem(at: staged)
            throw AtomicInstallError.moveFailed
        }
        do {
            // The image's signature was verified; the copy should not inherit a download quarantine flag.
            run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", staged.path])
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let result = try UpdateAtomicInstall.swap(
                installed: installed,
                incoming: staged,
                ops: DiskFileOps(),
                expectedBundleID: bundleID,
                timestamp: stamp
            )
            return result.backupURL
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    private nonisolated static func isPlainDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return (mode_t(info.st_mode) & S_IFMT) == S_IFDIR
    }

    /// Runs a tool with an argument array. No shell is involved.
    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// A detached shell waits for this process to exit, then opens the new bundle once.
    /// Any modal or sheet is closed first so terminate is not deferred, and the process
    /// exits on its own if terminate still has not finished after a few seconds.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "wyvern-relaunch",
            String(pid),
            appPath
        ]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            finish(true, message: "Updated. Quit and reopen the app to start the new version.")
            return
        }
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            exit(0)
        }
    }

    private func download(
        _ url: URL,
        to file: URL,
        maxBytes: Int64,
        allowsDevHTTP: Bool,
        timeout: TimeInterval,
        showsProgress: Bool
    ) async -> UpdateDownload.Outcome {
        let progress: @Sendable (Int64, Int64) -> Void
        if showsProgress {
            progress = { [weak self] received, expected in
                Task { @MainActor in
                    self?.sheet?.setProgress(received: received, expected: expected)
                }
            }
        } else {
            progress = { _, _ in }
        }
        let job = UpdateDownload(destination: file, maxBytes: maxBytes, allowsDevHTTP: allowsDevHTTP, onProgress: progress)
        activeDownload = job
        defer { activeDownload = nil }
        if cancelled { return .cancelled }
        return await job.run(url, timeout: timeout)
    }

    private func makeScratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wyvern-upd-\(UUID().uuidString)", isDirectory: true)
        try UpdatePackage.createPrivateDirectory(root)
        return root
    }

    private func finish(_ success: Bool, message: String) {
        appendLog(message)
        sheet?.finish(success: success, message: message, logURL: logURL)
    }

    private func appendLog(_ line: String) {
        let scrubbed = line.replacingOccurrences(of: "token=", with: "token=<redacted>")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(scrubbed)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Removes the previous app kept by the last update. Only a path the updater could
    /// have made (beside this app, `<name>.app.backup-<ts>`) is ever deleted.
    func clearBackupIfNeeded() {
        let path = settings.settings.pendingUpdateBackupPath
        guard !path.isEmpty else { return }
        let backup = URL(fileURLWithPath: path)
        let running = Bundle.main.bundleURL
        if backup.standardizedFileURL != running.standardizedFileURL,
           UpdateAtomicInstall.isBackup(backup, of: running) {
            try? FileManager.default.removeItem(at: backup)
        } else {
            appendLog("kept a stored backup path that is not beside this app")
        }
        settings.update { $0.pendingUpdateBackupPath = "" }
    }
}
