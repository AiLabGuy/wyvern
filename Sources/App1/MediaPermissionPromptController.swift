// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core

/// Window-modal sheet. Don't Allow is the default button and Escape.
@MainActor
final class MediaPermissionPromptController: NSWindowController {
    var onChoice: ((MediaPromptChoice) -> Void)?

    init(origin: String, kind: MediaCaptureKind) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Site permission"
        window.backgroundColor = Theme.page
        super.init(window: window)
        build(origin: origin, kind: kind)
        // The sheet is the AX-visible prompt (in the parent window's AXSheets).
        window.setAccessibilityIdentifier("app1.media.prompt")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(origin: String, kind: MediaCaptureKind) {
        guard let content = window?.contentView else { return }
        // Older runner builds look for this id on the content, which the bar also bridges.
        content.setAccessibilityIdentifier("app1.mediaPrompt")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(wrappingLabelWithString: headingText(kind))
        heading.font = Theme.font(size: 13, weight: .semibold)
        heading.textColor = Theme.text
        heading.preferredMaxLayoutWidth = 400

        let originLabel = NSTextField(labelWithString: origin)
        originLabel.font = Theme.mono(size: 12)
        originLabel.textColor = Theme.text
        originLabel.lineBreakMode = .byTruncatingMiddle

        let note = NSTextField(wrappingLabelWithString: "\(AppInfo.displayName) asks before a site can use this device. macOS may ask as well the first time.")
        note.font = Theme.font(size: 12)
        note.textColor = Theme.mute
        note.preferredMaxLayoutWidth = 400

        let allowOnce = NSButton(title: "Allow Once", target: self, action: #selector(chooseAllowOnce))
        allowOnce.bezelStyle = .rounded
        allowOnce.font = Theme.font(size: 13)
        allowOnce.setAccessibilityIdentifier("app1.mediaPrompt.allowOnce")

        let always = NSButton(title: "Always Allow on This Site", target: self, action: #selector(chooseAlways))
        always.bezelStyle = .rounded
        always.font = Theme.font(size: 13)
        always.setAccessibilityIdentifier("app1.mediaPrompt.alwaysAllow")

        let deny = NSButton(title: "Don't Allow", target: self, action: #selector(chooseDeny))
        deny.bezelStyle = .rounded
        deny.font = Theme.font(size: 13)
        deny.keyEquivalent = "\u{1b}"
        deny.setAccessibilityIdentifier("app1.mediaPrompt.deny")
        deny.setAccessibilityLabel("Don't Allow")

        let buttons = NSStackView(views: [allowOnce, always, deny])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [heading, originLabel, note, buttons] {
            stack.addArrangedSubview(view)
        }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        ])
        window?.defaultButtonCell = deny.cell as? NSButtonCell
        window?.initialFirstResponder = deny
    }

    private func headingText(_ kind: MediaCaptureKind) -> String {
        switch kind {
        case .microphone:
            return "This site wants to use the microphone"
        case .camera:
            return "This site wants to use the camera"
        case .both:
            return "This site wants to use the camera and microphone"
        }
    }

    override func cancelOperation(_ sender: Any?) {
        chooseDeny()
    }

    @objc private func chooseAllowOnce() { finish(.allowOnce) }
    @objc private func chooseAlways() { finish(.alwaysAllow) }
    @objc private func chooseDeny() { finish(.deny) }

    private func finish(_ choice: MediaPromptChoice) {
        let callback = onChoice
        onChoice = nil
        if let sheet = window {
            sheet.sheetParent?.endSheet(sheet)
        }
        callback?(choice)
    }
}
