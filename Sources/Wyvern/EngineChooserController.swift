// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// One-time sheet. DuckDuckGo is selected until the person confirms another engine.
@MainActor
final class EngineChooserController: NSWindowController {
    private let store: SettingsStore
    private var radios: [NSButton] = []
    private let templateField = NSTextField()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Choose a search engine"
        window.backgroundColor = Theme.page
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString: "Pick the engine used when the address field is not a site. You can change this later in Settings.")
        intro.font = Theme.font(size: 13)
        intro.textColor = Theme.text
        intro.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(intro)

        for engine in SearchEngine.builtIns {
            let radio = makeRadio(title: engine.name, selected: engine.id == SearchEngine.duckDuckGo.id)
            radio.identifier = NSUserInterfaceItemIdentifier(engine.id)
            radios.append(radio)
            stack.addArrangedSubview(radio)
        }
        let custom = makeRadio(title: "Custom", selected: false)
        custom.identifier = NSUserInterfaceItemIdentifier(SearchEngine.customID)
        radios.append(custom)
        stack.addArrangedSubview(custom)

        templateField.placeholderString = "https://example.com/search?q={query}"
        templateField.font = Theme.font(size: 13)
        templateField.isEnabled = false
        stack.addArrangedSubview(templateField)
        templateField.widthAnchor.constraint(equalToConstant: 400).isActive = true

        noteLabel.font = Theme.font(size: 12)
        noteLabel.textColor = Theme.mute
        noteLabel.stringValue = "A custom template must start with https:// and include {query}."
        noteLabel.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(noteLabel)

        let continueButton = NSButton(title: "Continue", target: self, action: #selector(confirm))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.font = Theme.font(size: 13)
        stack.addArrangedSubview(continueButton)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
        ])
    }

    private func makeRadio(title: String, selected: Bool) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioChanged))
        button.font = Theme.font(size: 13)
        button.state = selected ? .on : .off
        return button
    }

    @objc private func radioChanged(_ sender: NSButton) {
        for radio in radios where radio !== sender {
            radio.state = .off
        }
        sender.state = .on
        templateField.isEnabled = sender.identifier?.rawValue == SearchEngine.customID
    }

    @objc private func confirm() {
        let selected = radios.first { $0.state == .on }
        let identifier = selected?.identifier?.rawValue ?? SearchEngine.duckDuckGo.id
        if identifier == SearchEngine.customID {
            let template = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SearchEngine.custom(template: template) != nil else {
                noteLabel.stringValue = "That template is not valid. Use https and include {query}, or pick another engine."
                noteLabel.textColor = Theme.accent
                return
            }
            store.update { settings in
                settings.searchEngineID = SearchEngine.customID
                settings.customSearchTemplate = template
                settings.didChooseSearchEngine = true
            }
        } else {
            store.update { settings in
                settings.searchEngineID = identifier
                settings.didChooseSearchEngine = true
            }
        }
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}
