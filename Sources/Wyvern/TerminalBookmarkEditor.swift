// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import AppKit

struct TerminalBookmarkDraft {
    var name: String
    var command: String
    var workingDirectory: String
    var shell: String
    var openInNewTab: Bool
}

/// Sheet for a terminal bookmark. The command field keeps the whole string.
@MainActor
final class TerminalBookmarkEditor: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    var onSave: ((TerminalBookmarkDraft) -> Void)?
    var onDelete: (() -> Void)?

    private let nameWell = FieldWell()
    private let commandView = NSTextView()
    private let commandPlaceholder = PassLabel(frame: .zero)
    private let suggestionLabel = NSTextField(wrappingLabelWithString: "")
    private let suggestionRow = NSStackView()
    private let acceptPathButton = DepthButton(title: "Accept", kind: .secondary)
    private let pathWarning = NSTextField(wrappingLabelWithString: "")
    private let directoryWell = FieldWell()
    private let shellPopup = NSPopUpButton()
    private let newTabToggle = SettingsToggle(checkboxWithTitle: "Open in new tab", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = DepthButton(title: "Save", kind: .primary)
    private let pathResolver = CommandPathResolver(
        shell: LoginShellCommandRunner(),
        files: LiveCommandPathFileSystem()
    )
    private var resolution: CommandResolution?
    private var lookupGeneration = 0
    private let showsDelete: Bool

    private static let shellTooltip = "Default follows your login shell; pick an explicit one to force bash or sh. PATH additions from dotfiles may not apply, so a full path is safest."

    private enum CommandResolution {
        case lookingUp(command: String)
        case suggested(command: String, path: String)
        case missing(command: String, name: String)
    }

    init(draft: TerminalBookmarkDraft, showsDelete: Bool) {
        self.showsDelete = showsDelete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = showsDelete ? "Edit terminal bookmark" : "Add terminal bookmark"
        super.init(window: window)
        let surface = SheetSurface()
        window.contentView = surface
        build(draft: draft, in: surface)
        window.setAccessibilityIdentifier("wyvern.terminal.editor")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(draft: TerminalBookmarkDraft, in content: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = fieldLabel("Name")
        nameWell.textField.stringValue = draft.name
        nameWell.textField.placeholderString = "Dev server"
        nameWell.textField.font = Theme.font(size: 13)
        nameWell.textField.textColor = Theme.text
        nameWell.textField.delegate = self
        nameWell.textField.setAccessibilityIdentifier("wyvern.terminal.editor.name")

        let commandLabel = fieldLabel("Command")
        configureCommand(draft.command)
        let commandWell = commandContainer()
        configurePathSuggestion()

        let hint = NSTextField(wrappingLabelWithString: "Runs in a login shell. Use full paths for scripts.")
        hint.font = Theme.font(size: 11.5)
        hint.textColor = Theme.mute

        let warning = NSTextField(wrappingLabelWithString: TerminalBookmarkStore.sharingWarning)
        warning.font = Theme.font(size: 12)
        warning.textColor = Theme.mute

        let directoryLabel = fieldLabel("Working directory", optional: true)
        directoryWell.textField.stringValue = draft.workingDirectory
        directoryWell.textField.placeholderString = "~ (home)"
        directoryWell.textField.font = Theme.mono(size: 12.5)
        directoryWell.textField.textColor = Theme.text
        let folder = ToolButton()
        folder.glyph = .folder
        folder.pointSize = 14
        folder.tint = Theme.mute
        folder.target = self
        folder.action = #selector(pickDirectory)
        folder.setAccessibilityLabel("Choose folder")
        folder.translatesAutoresizingMaskIntoConstraints = false
        directoryWell.addSubview(folder)

        let shellLabel = fieldLabel("Shell", optional: true)
        configureShell(draft.shell)
        newTabToggle.state = draft.openInNewTab ? .on : .off
        newTabToggle.font = Theme.font(size: 13)
        newTabToggle.setAccessibilityIdentifier("wyvern.terminal.editor.openInNewTab")
        let shellRow = NSStackView(views: [shellPopup, newTabToggle])
        shellRow.orientation = .horizontal
        shellRow.alignment = .centerY
        shellRow.spacing = 16

        errorLabel.font = Theme.font(size: 12)
        errorLabel.textColor = Theme.destructive
        errorLabel.stringValue = ""

        func group(_ label: NSView, _ control: NSView) -> NSStackView {
            let column = NSStackView(views: [label, control])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            return column
        }

        let commandGroup = group(commandLabel, commandWell)
        stack.addArrangedSubview(group(nameLabel, nameWell))
        stack.addArrangedSubview(commandGroup)
        stack.setCustomSpacing(5, after: commandGroup)
        stack.addArrangedSubview(suggestionRow)
        stack.addArrangedSubview(pathWarning)
        stack.setCustomSpacing(5, after: pathWarning)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(warning)
        stack.addArrangedSubview(group(directoryLabel, directoryWell))
        stack.addArrangedSubview(group(shellLabel, shellRow))
        stack.addArrangedSubview(errorLabel)

        let footer = EditorFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let delete = DepthButton(title: "Delete", kind: .ghost)
        delete.titleColor = Theme.destructive
        delete.target = self
        delete.action = #selector(deleteTapped)
        delete.isHidden = !showsDelete
        delete.setAccessibilityIdentifier("wyvern.terminal.editor.delete")
        let cancel = DepthButton(title: "Cancel", kind: .secondary)
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.setAccessibilityIdentifier("wyvern.terminal.editor.cancel")
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.setAccessibilityIdentifier("wyvern.terminal.editor.save")
        let spacer = NSView()
        let buttons = NSStackView(views: [delete, spacer, cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        content.addSubview(stack)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            nameWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameWell.heightAnchor.constraint(equalToConstant: 34),
            commandWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandWell.heightAnchor.constraint(equalToConstant: 72),
            directoryWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directoryWell.heightAnchor.constraint(equalToConstant: 34),
            shellPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            suggestionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathWarning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folder.trailingAnchor.constraint(equalTo: directoryWell.trailingAnchor, constant: -6),
            folder.centerYAnchor.constraint(equalTo: directoryWell.centerYAnchor),
            folder.widthAnchor.constraint(equalToConstant: 26),
            folder.heightAnchor.constraint(equalToConstant: 26),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 60),
            footer.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        directoryWell.textFieldTrailing = 36
    }

    private func configureCommand(_ command: String) {
        commandView.isRichText = false
        commandView.isEditable = true
        commandView.isSelectable = true
        commandView.font = Theme.mono(size: 12.5)
        commandView.textColor = Theme.text
        commandView.backgroundColor = .clear
        commandView.string = command
        commandView.isAutomaticQuoteSubstitutionEnabled = false
        commandView.isAutomaticDashSubstitutionEnabled = false
        commandView.isAutomaticTextReplacementEnabled = false
        commandView.isAutomaticSpellingCorrectionEnabled = false
        commandView.isAutomaticDataDetectionEnabled = false
        commandView.isAutomaticLinkDetectionEnabled = false
        commandView.isVerticallyResizable = true
        commandView.isHorizontallyResizable = false
        commandView.textContainer?.widthTracksTextView = true
        commandView.textContainerInset = NSSize(width: 4, height: 6)
        commandView.minSize = NSSize(width: 0, height: 40)
        commandView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        commandView.autoresizingMask = [.width]
        commandView.frame = NSRect(x: 0, y: 0, width: 440, height: 60)
        commandView.delegate = self
        commandView.setAccessibilityIdentifier("wyvern.terminal.editor.command")
        commandPlaceholder.stringValue = "htop"
        commandPlaceholder.isEditable = false
        commandPlaceholder.isBordered = false
        commandPlaceholder.isBezeled = false
        commandPlaceholder.drawsBackground = false
        commandPlaceholder.font = Theme.mono(size: 12.5)
        commandPlaceholder.textColor = Theme.mute
        commandPlaceholder.isHidden = !command.isEmpty
    }

    private func commandContainer() -> NSView {
        let well = FieldWell()
        well.textField.isHidden = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = commandView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        commandPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        well.addSubview(commandPlaceholder)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2),
            commandPlaceholder.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 12),
            commandPlaceholder.centerYAnchor.constraint(equalTo: well.centerYAnchor)
        ])
        return well
    }

    private func configureShell(_ shell: String) {
        let choices = [
            ("Default (login shell)", ""),
            ("/bin/zsh", "/bin/zsh"),
            ("/bin/bash", "/bin/bash"),
            ("/bin/sh", "/bin/sh")
        ]
        shellPopup.removeAllItems()
        for (title, value) in choices {
            shellPopup.addItem(withTitle: title)
            shellPopup.lastItem?.representedObject = value
        }
        if !shell.isEmpty, !choices.contains(where: { $0.1 == shell }) {
            shellPopup.addItem(withTitle: shell)
            shellPopup.lastItem?.representedObject = shell
        }
        let match = shellPopup.itemArray.firstIndex { ($0.representedObject as? String) == shell }
        if let match {
            shellPopup.selectItem(at: match)
        }
        shellPopup.font = Theme.font(size: 13)
        shellPopup.toolTip = Self.shellTooltip
        shellPopup.setAccessibilityIdentifier("wyvern.terminal.editor.shell")
    }

    private func configurePathSuggestion() {
        suggestionLabel.font = Theme.font(size: 12)
        suggestionLabel.textColor = Theme.text
        suggestionLabel.maximumNumberOfLines = 2
        suggestionLabel.preferredMaxLayoutWidth = 380
        suggestionLabel.setAccessibilityIdentifier("wyvern.terminal.editor.pathSuggestion")
        suggestionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        acceptPathButton.applySettingsStyle()
        acceptPathButton.target = self
        acceptPathButton.action = #selector(acceptSuggestedPath)
        acceptPathButton.setAccessibilityIdentifier("wyvern.terminal.editor.acceptPath")
        acceptPathButton.setContentHuggingPriority(.required, for: .horizontal)
        suggestionRow.orientation = .horizontal
        suggestionRow.alignment = .centerY
        suggestionRow.spacing = 8
        suggestionRow.addArrangedSubview(suggestionLabel)
        suggestionRow.addArrangedSubview(acceptPathButton)
        suggestionRow.isHidden = true
        pathWarning.font = Theme.font(size: 12)
        pathWarning.textColor = Theme.mute
        pathWarning.maximumNumberOfLines = 3
        pathWarning.preferredMaxLayoutWidth = 472
        pathWarning.setAccessibilityIdentifier("wyvern.terminal.editor.pathWarning")
        pathWarning.isHidden = true
    }

    private func fieldLabel(_ title: String, optional: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: Theme.font(size: 12, weight: .semibold),
                .foregroundColor: Theme.text
            ]
        )
        if optional {
            text.append(NSAttributedString(
                string: " (optional)",
                attributes: [
                    .font: Theme.font(size: 12),
                    .foregroundColor: Theme.mute
                ]
            ))
        }
        label.attributedStringValue = text
        return label
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === commandView else { return }
        commandPlaceholder.isHidden = !commandView.string.isEmpty
        switch resolution {
        case .lookingUp(let command), .suggested(let command, _), .missing(let command, _):
            if command != commandView.string {
                clearResolution()
            }
        case nil:
            break
        }
    }

    @objc private func pickDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.directoryWell.textField.stringValue = url.path
        }
    }

    @objc private func saveTapped() {
        let name = nameWell.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandView.string
        guard !name.isEmpty, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorLabel.stringValue = "Name and command are required."
            return
        }
        errorLabel.stringValue = ""
        if CommandWords.bareName(in: command) != nil {
            switch resolution {
            case .lookingUp:
                return
            case .missing(let original, _), .suggested(let original, _) where original == command:
                commitDraft()
            default:
                startLookup(command)
            }
            return
        }
        commitDraft()
    }

    /// Looks up a bare name off the main thread. The field is not rewritten unless the user accepts.
    private func startLookup(_ command: String) {
        lookupGeneration += 1
        let generation = lookupGeneration
        resolution = .lookingUp(command: command)
        saveButton.isEnabled = false
        let resolver = pathResolver
        Task.detached(priority: .userInitiated) {
            let outcome = resolver.resolve(command)
            await MainActor.run { [weak self] in
                self?.applyResolution(outcome, generation: generation, command: command)
            }
        }
    }

    private func applyResolution(_ outcome: CommandPathResolution, generation: Int, command: String) {
        guard generation == lookupGeneration, commandView.string == command else { return }
        saveButton.isEnabled = true
        switch outcome {
        case .unchanged:
            resolution = nil
            commitDraft()
        case .suggested(_, let path):
            resolution = .suggested(command: command, path: path)
            suggestionLabel.stringValue = "Use \(path)?"
            suggestionRow.isHidden = false
            pathWarning.stringValue = ""
            pathWarning.isHidden = true
        case .notFound(let name):
            resolution = .missing(command: command, name: name)
            pathWarning.stringValue = "Couldn't find \(name) on your login PATH. A full path is safest."
            pathWarning.isHidden = false
            suggestionLabel.stringValue = ""
            suggestionRow.isHidden = true
        }
    }

    @objc private func acceptSuggestedPath() {
        guard case .suggested(_, let path) = resolution else { return }
        let updated = CommandWords.replacingFirstWord(in: commandView.string, with: path)
        commandView.string = updated
        commandPlaceholder.isHidden = !updated.isEmpty
        clearResolution()
    }

    private func clearResolution() {
        lookupGeneration += 1
        resolution = nil
        suggestionLabel.stringValue = ""
        suggestionRow.isHidden = true
        pathWarning.stringValue = ""
        pathWarning.isHidden = true
        saveButton.isEnabled = true
    }

    private func commitDraft() {
        let name = nameWell.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandView.string
        let directory = directoryWell.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = shellPopup.selectedItem?.representedObject as? String ?? ""
        onSave?(TerminalBookmarkDraft(
            name: name,
            command: command,
            workingDirectory: directory,
            shell: shell,
            openInNewTab: newTabToggle.state == .on
        ))
        closeSheet()
    }

    @objc private func cancelTapped() {
        closeSheet()
    }

    @objc private func deleteTapped() {
        onDelete?()
        closeSheet()
    }

    private func closeSheet() {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}

@MainActor
private final class PassLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class SheetSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        Theme.fillGradient(top: Theme.card, bottom: Theme.page, path: path)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class EditorFooter: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.fillBarGradient(in: bounds)
        Theme.line.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class FieldWell: NSView {
    let textField = NSTextField()
    var textFieldTrailing: CGFloat = 10 {
        didSet { trailingConstraint?.constant = -textFieldTrailing }
    }
    private var trailingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        let trailing = textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        trailingConstraint = trailing
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            trailing,
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        FieldFrame.draw(in: bounds, radius: 8)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
