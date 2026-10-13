// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import Foundation

/// Debounced live snapshot plus the frozen snapshot from the previous run.
@MainActor
final class SessionCoordinator {
    let archive: SessionArchive
    private(set) var previous: SessionSnapshot?
    private(set) var offerCrashRestore = false
    private var generation = 0
    private var terminating = false
    var capture: () -> SessionSnapshot = { SessionSnapshot(windows: []) }

    init(directory: URL) {
        archive = SessionArchive(directory: directory)
    }

    var canRestorePrevious: Bool {
        previous?.hasRestorableTabs == true
    }

    func beginRun() {
        let state = archive.beginRun()
        previous = state.previous
        offerCrashRestore = state.offerCrashRestore
    }

    /// Coalesce tab and window edits. The timer is about one second.
    func scheduleSave() {
        guard !terminating else { return }
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, !self.terminating else { return }
                self.saveNow()
            }
        }
    }

    func saveNow() {
        guard !terminating else { return }
        _ = archive.saveLive(capture())
    }

    /// Flush the open windows, then record a clean exit so the next launch does not offer crash restore.
    /// A second call does nothing, so a later teardown cannot replace the snapshot with an empty one.
    func finish() {
        guard !terminating else { return }
        terminating = true
        generation += 1
        _ = archive.saveLive(capture())
        archive.markCleanExit()
    }
}
