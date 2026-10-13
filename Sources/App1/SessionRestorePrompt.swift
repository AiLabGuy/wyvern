// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit

/// Small sheet asking whether to reopen tabs after an unclean exit.
@MainActor
final class SessionRestorePrompt: NSWindowController {
    var onChoice: ((Bool) -> Void)?
    private var didChoose = false
    private let restoreButton = DepthButton(title: "Restore", kind: .primary)
    private let notNowButton = DepthButton(title: "Not now", kind: .secondary)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 168),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Restore previous session?"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.win
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        build()
        window.setAccessibilityIdentifier("app1.sessionRestore")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: "Restore previous session?")
        title.font = Theme.font(size: 18, weight: .bold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityIdentifier("app1.sessionRestore.title")

        let detail = NSTextField(wrappingLabelWithString: "Wyvern did not quit cleanly last time. You can reopen the tabs from that session.")
        detail.font = Theme.font(size: 13)
        detail.textColor = Theme.mute
        detail.maximumNumberOfLines = 3
        detail.translatesAutoresizingMaskIntoConstraints = false

        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        restoreButton.keyEquivalent = "\r"
        restoreButton.setAccessibilityIdentifier("app1.sessionRestore.restore")
        notNowButton.target = self
        notNowButton.action = #selector(notNowTapped)
        notNowButton.keyEquivalent = "\u{1b}"
        notNowButton.setAccessibilityIdentifier("app1.sessionRestore.notNow")

        let buttons = NSStackView(views: [notNowButton, restoreButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(detail)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    @objc private func restoreTapped() {
        choose(true)
    }

    @objc private func notNowTapped() {
        choose(false)
    }

    private func choose(_ restore: Bool) {
        guard !didChoose else { return }
        didChoose = true
        onChoice?(restore)
    }
}
