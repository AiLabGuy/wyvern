// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit
import Darwin
import Foundation
import WebKit

#if compiler(>=6)
typealias DownloadDestinationHandler = @MainActor @Sendable (URL?) -> Void
#else
typealias DownloadDestinationHandler = (URL?) -> Void
#endif

extension Notification.Name {
    static let app1DownloadsDidChange = Notification.Name("app1DownloadsDidChange")
}

@MainActor
final class DownloadRecord {
    enum State {
        case active
        case finished
        case failed
        case cancelled
    }

    let id = UUID()
    var filename: String
    var finalURL: URL?
    var tempURL: URL?
    var received: Int64 = 0
    var total: Int64 = 0
    var state: State = .active
    var download: WKDownload?
    var progressObservation: NSKeyValueObservation?
    var userInitiated: Bool
    /// The save panel already confirmed this path, so a file already there is replaced.
    var replacesExisting = false

    init(filename: String, userInitiated: Bool) {
        self.filename = filename
        self.userInitiated = userInitiated
    }
}

struct DownloadBehavior {
    var directory: URL
    var askEachTime: Bool
    var openWhenFinished: Bool

    static var systemDefault: DownloadBehavior {
        DownloadBehavior(
            directory: AppLocations.downloadsDirectory,
            askEachTime: false,
            openWhenFinished: false
        )
    }
}

/// Session download list. Nothing is persisted.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadManager()

    private(set) var items: [DownloadRecord] = []
    var revealPopoverWhenNonEmpty = false
    /// Read on the main actor when a download chooses its destination.
    var behavior: () -> DownloadBehavior = { .systemDefault }
    private var occupiedExtras: Set<String> = []

    var hasActiveDownload: Bool {
        items.contains { $0.state == .active }
    }

    func adopt(_ download: WKDownload, userInitiated: Bool) {
        if items.contains(where: { $0.download === download }) {
            return
        }
        download.delegate = self
        let record = DownloadRecord(filename: "download", userInitiated: userInitiated)
        record.download = download
        observe(record, download: download)
        items.append(record)
        notify(pulse: userInitiated, reveal: false)
    }

    func cancel(_ record: DownloadRecord) {
        record.download?.cancel()
        record.state = .cancelled
        removePartial(record)
        record.download = nil
        notify(pulse: false, reveal: false)
    }

    func clearFinished() {
        items.removeAll { $0.state != .active }
        notify(pulse: false, reveal: false)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping DownloadDestinationHandler
    ) {
        let work = { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            self.place(download, suggestedFilename: suggestedFilename, completionHandler: completionHandler)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(work)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        hop {
            self.finish(download)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        _ = error
        _ = resumeData
        hop {
            self.fail(download)
        }
    }

    private func place(
        _ download: WKDownload,
        suggestedFilename: String,
        completionHandler: @escaping DownloadDestinationHandler
    ) {
        let prefs = behavior()
        if prefs.askEachTime {
            askWhereToSave(suggestedFilename: suggestedFilename, directory: prefs.directory) { [weak self] chosen in
                guard let self, let chosen else {
                    completionHandler(nil)
                    return
                }
                let name = chosen.lastPathComponent
                if name.isEmpty || name == "." || name == "/" {
                    completionHandler(nil)
                    return
                }
                self.commitPlacement(
                    download: download,
                    folder: chosen.deletingLastPathComponent(),
                    finalName: name,
                    tempName: nil,
                    replacesExisting: true,
                    completionHandler: completionHandler
                )
            }
            return
        }
        let folder = prefs.directory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let occupied = listedNames(in: folder).union(occupiedExtras)
        let names = DownloadNaming.allocate(desired: suggestedFilename, occupied: occupied)
        commitPlacement(
            download: download,
            folder: folder,
            finalName: names.finalName,
            tempName: names.tempName,
            replacesExisting: false,
            completionHandler: completionHandler
        )
    }

    /// "Open after download" never launches code: apps, installers, scripts, and executables stay closed.
    static func isSafeToOpenAutomatically(_ url: URL) -> Bool {
        let blocked: Set<String> = [
            "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "py", "pl", "rb",
            "scpt", "applescript", "workflow", "jar", "pkg", "mpkg", "dmg", "action", "prefpane",
            "webloc", "inetloc", "fileloc", "url", "osax", "plugin", "bundle", "kext", "dylib",
        ]
        if blocked.contains(url.pathExtension.lowercased()) { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return !FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func askWhereToSave(suggestedFilename: String, directory: URL, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.nameFieldStringValue = DownloadNaming.sanitize(suggestedFilename)
        panel.prompt = "Save"
        panel.title = "Save Download"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK {
                completion(panel.url)
            } else {
                completion(nil)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        finish(response)
                    }
                }
            }
        } else {
            finish(panel.runModal())
        }
    }

    private func commitPlacement(
        download: WKDownload,
        folder: URL,
        finalName: String,
        tempName: String?,
        replacesExisting: Bool,
        completionHandler: @escaping DownloadDestinationHandler
    ) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let resolvedTemp: String
        if let tempName {
            resolvedTemp = tempName
        } else {
            let occupied = listedNames(in: folder).union(occupiedExtras)
            resolvedTemp = DownloadNaming.allocate(desired: finalName, occupied: occupied).tempName
        }
        occupiedExtras.insert(finalName)
        occupiedExtras.insert(resolvedTemp)
        let tempURL = folder.appendingPathComponent(resolvedTemp)
        let finalURL = folder.appendingPathComponent(finalName)
        let record: DownloadRecord
        if let existing = items.first(where: { $0.download === download }) {
            record = existing
        } else {
            let created = DownloadRecord(filename: finalName, userInitiated: false)
            created.download = download
            items.append(created)
            record = created
        }
        record.filename = finalName
        record.tempURL = tempURL
        record.finalURL = finalURL
        record.replacesExisting = replacesExisting
        let expected = download.progress.totalUnitCount
        if expected > 0 {
            record.total = expected
        }
        notify(pulse: false, reveal: revealPopoverWhenNonEmpty)
        completionHandler(tempURL)
    }

    private func finish(_ download: WKDownload) {
        guard let record = items.first(where: { $0.download === download }) else { return }
        record.progressObservation?.invalidate()
        record.progressObservation = nil
        let allocatedName = record.filename
        var finalName = record.filename
        let fallbackFolder = behavior().directory
        var destination = record.finalURL ?? fallbackFolder.appendingPathComponent(finalName)
        let folder = destination.deletingLastPathComponent()
        if record.replacesExisting {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            let occupied = listedNames(in: folder)
            let names = DownloadNaming.allocate(desired: finalName, occupied: occupied)
            finalName = names.finalName
            destination = folder.appendingPathComponent(finalName)
        }
        if let temp = record.tempURL, FileManager.default.fileExists(atPath: temp.path) {
            do {
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                record.state = .failed
                removePartial(record)
                notify(pulse: false, reveal: false)
                return
            }
        }
        record.filename = finalName
        record.finalURL = destination
        record.tempURL = nil
        record.state = .finished
        record.download = nil
        if record.total <= 0 {
            if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value {
                record.received = size
                record.total = size
            }
        } else {
            record.received = record.total
        }
        applyQuarantine(to: destination)
        if behavior().openWhenFinished, FileManager.default.fileExists(atPath: destination.path),
           Self.isSafeToOpenAutomatically(destination) {
            NSWorkspace.shared.open(destination)
        }
        // Release the names reserved in `place`, even when the final name moved on.
        occupiedExtras.remove(allocatedName)
        occupiedExtras.remove(allocatedName + ".download")
        occupiedExtras.remove(finalName)
        occupiedExtras.remove(finalName + ".download")
        notify(pulse: false, reveal: revealPopoverWhenNonEmpty)
    }

    private func fail(_ download: WKDownload) {
        guard let record = items.first(where: { $0.download === download }) else { return }
        record.progressObservation?.invalidate()
        record.progressObservation = nil
        if record.state == .active {
            record.state = .failed
        }
        removePartial(record)
        record.download = nil
        notify(pulse: false, reveal: false)
    }

    private func observe(_ record: DownloadRecord, download: WKDownload) {
        record.progressObservation = download.progress.observe(\.completedUnitCount, options: [.new, .initial]) { [weak record] progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let record else { return }
                    record.received = received
                    if total > 0 {
                        record.total = total
                    }
                    NotificationCenter.default.post(name: .app1DownloadsDidChange, object: nil)
                }
            }
        }
    }

    private func listedNames(in folder: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(contents)
    }

    private func removePartial(_ record: DownloadRecord) {
        if let temp = record.tempURL {
            try? FileManager.default.removeItem(at: temp)
        }
        if let name = record.finalURL?.lastPathComponent {
            occupiedExtras.remove(name)
            occupiedExtras.remove(name + ".download")
        }
        occupiedExtras.remove(record.filename)
        occupiedExtras.remove(record.filename + ".download")
        record.tempURL = nil
        record.finalURL = nil
    }

    private func applyQuarantine(to url: URL) {
        let value = QuarantineAttribute.value(
            unixTime: UInt64(Date().timeIntervalSince1970),
            uuid: UUID()
        )
        _ = value.withCString { pointer in
            setxattr(url.path, QuarantineAttribute.name, pointer, value.utf8.count, 0, 0)
        }
    }

    private func notify(pulse: Bool, reveal: Bool) {
        var info: [String: Bool] = [:]
        if pulse {
            info["pulse"] = true
        }
        if reveal {
            info["reveal"] = true
            revealPopoverWhenNonEmpty = false
        }
        NotificationCenter.default.post(name: .app1DownloadsDidChange, object: nil, userInfo: info)
    }

    private func hop(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
        }
    }
}
