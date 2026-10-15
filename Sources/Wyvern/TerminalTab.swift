// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit
import Darwin
import SwiftTerm

/// SwiftTerm's default command-click handler opens the link with `NSWorkspace`.
/// A subclass replaces that with http and https only. `LocalProcessTerminalView` is open
/// so this can implement the delegate method the superclass leaves to the protocol default.
final class WyvernTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Called from the view's mouse handler. Do not touch view state here.
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let raw = link
        Task { @MainActor in
            guard TerminalLinkPolicy.allows(raw), let url = URL(string: raw) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// A terminal tab. The header string is the command the user stored. Shell titles are ignored.
@MainActor
final class TerminalTab: LocalProcessTerminalViewDelegate {
    let id = UUID()
    let bookmarkID: UUID
    let name: String
    /// Full command, shown verbatim in the tab header, tooltip, and accessibility value.
    let command: String
    /// Absolute shell used as argv0. Not interpolated into the command.
    let shell: String
    /// Expanded working directory, or nil for the login shell's home directory.
    let workingDirectory: String?
    /// Shell name and directory shown in the address field. Not a substitute for `command`.
    let fieldCaption: String
    var fontSize: CGFloat = 13
    let view: LocalProcessTerminalView
    private var didStart = false

    init(
        bookmarkID: UUID,
        name: String,
        command: String,
        shell: String = "/bin/zsh",
        workingDirectory: String? = nil,
        fieldCaption: String = ""
    ) {
        self.bookmarkID = bookmarkID
        self.name = name
        self.command = command
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.fieldCaption = fieldCaption.isEmpty ? TerminalLaunch.fieldCaption(shell: shell, directory: "") : fieldCaption
        let created = WyvernTerminalView(frame: .zero)
        created.font = Theme.mono(size: 13)
        view = created
    }

    /// The delegate is weak. Call this after the tab is retained by the window.
    func attach() {
        view.processDelegate = self
        applyColors()
    }

    func applyColors() {
        view.font = Theme.mono(size: fontSize)
        view.nativeBackgroundColor = Theme.termBackground
        view.nativeForegroundColor = Theme.termText
        view.caretColor = Theme.termText
    }

    /// Stored shell, then `-lc` and the stored command as one argv element.
    func start() {
        guard !didStart else { return }
        didStart = true
        let argv = TerminalLaunch.arguments(shell: shell, command: command)
        guard let executable = argv.first else { return }
        view.startProcess(
            executable: executable,
            args: Array(argv.dropFirst()),
            environment: nil,
            execName: nil,
            currentDirectory: workingDirectory
        )
    }

    /// `kill(pid, 0)` succeeds for a live process. `EPERM` means it exists and we cannot signal it.
    func isProcessRunning() -> Bool {
        let pid = view.process?.shellPid ?? 0
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    /// SIGTERM the process group, then SIGKILL, then ask the view to reap its child.
    func shutdown() {
        let pid = view.process?.shellPid ?? 0
        if pid > 1 {
            _ = kill(-pid, SIGTERM)
            if kill(pid, 0) == 0 || errno == EPERM {
                _ = kill(-pid, SIGKILL)
            }
        }
        view.terminate()
    }

    /// Protocol witnesses stay nonisolated. SwiftTerm can call them off the main queue, and they do not touch the tab.
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // The shell's OSC title does not replace the command in the tab header.
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
