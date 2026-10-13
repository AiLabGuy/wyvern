// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core

enum UpdateStep: String {
    case download = "Downloading"
    case verify = "Verifying"
    case install = "Installing"
}

/// Check result and progress for one update run. `AppUpdater` keeps this controller alive
/// while its window is up; NSButton targets are weak.
@MainActor
final class UpdateSheetController: NSWindowController {
    var onCancel: (() -> Void)?
    var onInstall: (() -> Void)?
    var onClose: (() -> Void)?
    private let stack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let installButton = NSButton(title: "Update and Relaunch", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private var logURL: URL?
    private var phase: Phase = .working

    private enum Phase {
        case working
        case offering
        case installing
        case done
    }

    private static let width: CGFloat = 460

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 170),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.backgroundColor = Theme.page
        super.init(window: window)
        build()
        window.setAccessibilityIdentifier("app1.update.sheet")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let textWidth = Self.width - 40
        status.font = Theme.font(size: 13, weight: .semibold)
        status.textColor = Theme.text
        status.preferredMaxLayoutWidth = textWidth
        status.setAccessibilityIdentifier("app1.update.status")
        details.font = Theme.font(size: 12)
        details.textColor = Theme.mute
        details.preferredMaxLayoutWidth = textWidth
        details.maximumNumberOfLines = 14
        details.isSelectable = true
        details.setAccessibilityIdentifier("app1.update.details")
        progress.isIndeterminate = true
        progress.style = .bar
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.setAccessibilityIdentifier("app1.update.install")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("app1.update.cancel")
        logButton.bezelStyle = .rounded
        logButton.target = self
        logButton.action = #selector(showLog)
        logButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [logButton, spacer, cancelButton, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.setViews([status, details, progress, buttons], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            progress.widthAnchor.constraint(equalToConstant: textWidth),
            buttons.widthAnchor.constraint(equalToConstant: textWidth)
        ])
    }

    func showChecking() {
        phase = .working
        status.textColor = Theme.text
        status.stringValue = "Checking for updates…"
        details.stringValue = ""
        details.isHidden = true
        showProgress(indeterminate: true)
        installButton.isHidden = true
        cancelButton.title = "Cancel"
        cancelButton.isEnabled = true
        resizeToFit()
    }

    func showAvailable(headline: String, details text: String) {
        phase = .offering
        status.stringValue = headline
        details.stringValue = text
        details.isHidden = false
        progress.stopAnimation(nil)
        progress.isHidden = true
        installButton.isHidden = false
        installButton.isEnabled = true
        installButton.keyEquivalent = "\r"
        cancelButton.title = "Not Now"
        cancelButton.isEnabled = true
        resizeToFit()
    }

    func setStep(_ step: UpdateStep, detail: String) {
        phase = step == .install ? .installing : .working
        status.textColor = Theme.text
        status.stringValue = "\(step.rawValue)…"
        details.stringValue = detail
        details.isHidden = detail.isEmpty
        showProgress(indeterminate: true)
        installButton.isHidden = true
        installButton.keyEquivalent = ""
        cancelButton.title = "Cancel"
        // The swap cannot be interrupted halfway; it either completes or rolls back.
        cancelButton.isEnabled = step != .install
        resizeToFit()
    }

    func setProgress(received: Int64, expected: Int64) {
        guard phase == .working else { return }
        let megabytes = Double(received) / 1_048_576
        if expected > 0 {
            progress.isIndeterminate = false
            progress.maxValue = Double(expected)
            progress.doubleValue = Double(received)
            details.stringValue = String(format: "%.1f of %.1f MB", megabytes, Double(expected) / 1_048_576)
        } else {
            details.stringValue = String(format: "%.1f MB", megabytes)
        }
        details.isHidden = false
    }

    func finish(success: Bool, message: String, logURL: URL?) {
        phase = .done
        self.logURL = logURL
        progress.stopAnimation(nil)
        progress.isHidden = true
        status.stringValue = message
        status.textColor = success ? Theme.text : Theme.color(hex: "#C62828")
        details.isHidden = true
        installButton.isHidden = true
        installButton.keyEquivalent = ""
        cancelButton.title = "Close"
        cancelButton.isEnabled = true
        cancelButton.keyEquivalent = "\r"
        logButton.isHidden = logURL == nil
        resizeToFit()
    }

    private func showProgress(indeterminate: Bool) {
        progress.isHidden = false
        progress.isIndeterminate = indeterminate
        progress.startAnimation(nil)
    }

    private func resizeToFit() {
        guard let window else { return }
        stack.layoutSubtreeIfNeeded()
        let height = max(140, stack.fittingSize.height + 36)
        window.setContentSize(NSSize(width: Self.width, height: height))
    }

    @objc private func installTapped() {
        guard phase == .offering else { return }
        onInstall?()
    }

    @objc private func cancelTapped() {
        switch phase {
        case .installing:
            return
        case .working, .offering:
            onCancel?()
        case .done:
            break
        }
        dismiss()
    }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        onClose?()
    }

    @objc private func showLog() {
        guard let logURL else { return }
        NSWorkspace.shared.open(logURL)
    }
}
