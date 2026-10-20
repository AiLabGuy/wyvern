// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// Settings → Appearance → Icons. Built with the pane's section, card, and row helpers.
@MainActor
class IconSettingsSection: NSObject {
    private weak var pane: SettingsWindowController?
    private let statusLabel = SettingsLabel(role: .detail, text: "")
    private let hostStatus = SettingsLabel(role: .detail, text: "")
    private let hostFrame = SettingsFieldFrame()
    private let hostList = NSStackView()
    private var styleButtons: [IconStyleChoice] = []
    private let styleRow = NSStackView()

    func append(to column: NSStackView, pane: SettingsWindowController) {
        self.pane = pane
        guard let anchor = column.arrangedSubviews.last else { return }
        pane.addGroup("Icons", id: "wyvern.settings.section.icons", to: column, after: anchor)

        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.distribution = .fillEqually
        styleRow.spacing = 8
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        rebuildStyleButtons()
        let styles = pane.makeCard(padded: true)
        styles.stack.addArrangedSubview(styleRow)
        styleRow.widthAnchor.constraint(equalTo: styles.stack.widthAnchor).isActive = true
        styleRow.heightAnchor.constraint(equalToConstant: 96).isActive = true
        pane.addCard(styles.host, to: column)

        let choose = DepthButton(title: "Choose…", kind: .secondary)
        styleSettingsButton(choose)
        choose.target = self
        choose.action = #selector(chooseAppIcon)
        choose.setAccessibilityIdentifier("wyvern.settings.icons.choose")
        choose.setAccessibilityLabel("Choose an app icon image")
        let reset = DepthButton(title: "Reset to Default", kind: .secondary)
        styleSettingsButton(reset)
        reset.target = self
        reset.action = #selector(resetAppIcon)
        reset.setAccessibilityIdentifier("wyvern.settings.icons.reset")
        reset.setAccessibilityLabel("Reset to Default")
        let actions = pane.makeCard(padded: false)
        pane.span(pane.makeRow(
            title: "Your image",
            detail: "PNG, JPEG, ICNS, or HEIC, up to 5 MB.",
            control: choose
        ), in: actions.stack)
        pane.span(SettingsHairline(), in: actions.stack)
        pane.span(pane.makeRow(
            title: "App icon",
            detailLabel: statusLabel,
            control: reset
        ), in: actions.stack)
        pane.addCard(actions.host, to: column)
        _ = pane.addNote(
            "The Dock icon changes while Wyvern is running. Finder keeps the app's signed icon; an unsigned app cannot change that without breaking its code signature.",
            to: column
        )

        hostFrame.field.placeholderString = "example.com"
        hostFrame.field.setAccessibilityIdentifier("wyvern.settings.icons.host")
        hostFrame.field.setAccessibilityLabel("Site host")
        hostFrame.translatesAutoresizingMaskIntoConstraints = false
        hostFrame.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let hostChoose = DepthButton(title: "Choose…", kind: .secondary)
        styleSettingsButton(hostChoose)
        hostChoose.target = self
        hostChoose.action = #selector(chooseHostIcon)
        hostChoose.setAccessibilityIdentifier("wyvern.settings.icons.hostChoose")
        hostChoose.setAccessibilityLabel("Choose a site icon")
        let cluster = NSStackView(views: [hostFrame, hostChoose])
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = 8
        cluster.translatesAutoresizingMaskIntoConstraints = false
        let sites = pane.makeCard(padded: false)
        pane.span(pane.makeRow(
            title: "Site tab icon",
            detailLabel: hostStatus,
            control: cluster
        ), in: sites.stack)
        pane.span(SettingsHairline(), in: sites.stack)
        hostList.orientation = .vertical
        hostList.alignment = .leading
        hostList.spacing = 0
        hostList.translatesAutoresizingMaskIntoConstraints = false
        hostList.setAccessibilityIdentifier("wyvern.settings.icons.hosts")
        sites.stack.addArrangedSubview(hostList)
        hostList.widthAnchor.constraint(equalTo: sites.stack.widthAnchor).isActive = true
        pane.addCard(sites.host, to: column)
        hostStatus.plain = "Replaces the favicon in the tab strip."
        reloadHosts()
        refreshStyleSelection()
    }

    @objc private func chooseAppIcon() {
        IconPickPanel.choose(from: pane?.window) { [weak self] url in
            Task { @MainActor in
                guard let self, let url else { return }
                if let error = IconController.shared.installAppIcon(from: url) {
                    self.statusLabel.plain = IconController.message(for: error)
                } else {
                    self.statusLabel.plain = ""
                }
                self.rebuildStyleButtons()
            }
        }
    }

    @objc private func resetAppIcon() {
        if let error = IconController.shared.resetAppIcon() {
            statusLabel.plain = IconController.message(for: error)
        } else {
            statusLabel.plain = ""
        }
        rebuildStyleButtons()
    }

    @objc private func stylePicked(_ sender: NSButton) {
        guard let choice = sender as? IconStyleChoice else { return }
        if let style = choice.style {
            if let error = IconController.shared.setBuiltIn(style) {
                statusLabel.plain = IconController.message(for: error)
            } else if style != .default, IconController.bundledStyleImage(style) == nil {
                statusLabel.plain = "That style is not in this build."
            } else {
                statusLabel.plain = ""
            }
        } else if IconController.shared.library.customAppIconURL() != nil {
            IconController.shared.applyDockIcon()
            statusLabel.plain = ""
        }
        // Picking a built-in drops the custom file, so the Custom preview must leave too.
        rebuildStyleButtons()
    }

    @objc private func chooseHostIcon() {
        let raw = hostFrame.field.stringValue
        guard IconHostKey.normalize(raw) != nil else {
            hostStatus.plain = IconController.message(for: .invalidHost)
            return
        }
        IconPickPanel.choose(from: pane?.window) { [weak self] url in
            Task { @MainActor in
                guard let self, let url else { return }
                switch IconController.shared.installHostIcon(host: raw, from: url) {
                case .success:
                    self.hostFrame.field.stringValue = ""
                    self.hostStatus.plain = "Replaces the favicon in the tab strip."
                    self.reloadHosts()
                case .failure(let error):
                    self.hostStatus.plain = IconController.message(for: error)
                }
            }
        }
    }

    @objc private func removeHost(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        IconController.shared.removeHostIcon(key)
        hostStatus.plain = "Replaces the favicon in the tab strip."
        reloadHosts()
    }

    private func rebuildStyleButtons() {
        for view in styleRow.arrangedSubviews {
            styleRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        styleButtons = []
        var kinds: [(AppIconStyle?, String)] = [
            (.default, "Default"),
            (.graphite, "Graphite"),
            (.hermes, "Hermes"),
            (.neon, "Neon")
        ]
        if case .custom = IconController.shared.library.appIcon {
            kinds.append((nil, "Custom"))
        }
        for (style, title) in kinds {
            let button = IconStyleChoice(title: title, style: style)
            button.target = self
            button.action = #selector(stylePicked(_:))
            if let style {
                button.icon = IconController.bundledStyleImage(style)
                button.setAccessibilityIdentifier("wyvern.settings.icons.style.\(style.rawValue)")
            } else if let url = IconController.shared.library.customAppIconURL() {
                button.icon = NSImage(contentsOf: url)
                button.setAccessibilityIdentifier("wyvern.settings.icons.style.custom")
            }
            styleRow.addArrangedSubview(button)
            styleButtons.append(button)
        }
        refreshStyleSelection()
    }

    private func refreshStyleSelection() {
        let current = IconController.shared.library.appIcon
        for button in styleButtons {
            switch current {
            case .style(let style):
                button.picked = button.style == style
            case .custom:
                button.picked = button.style == nil
            }
            button.refreshAccessibility()
        }
    }

    private func reloadHosts() {
        guard let pane else { return }
        for view in hostList.arrangedSubviews {
            hostList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let keys = IconController.shared.library.hostKeys()
        if keys.isEmpty {
            let spacer = NSView()
            let row = pane.makeRow(title: "No site icons yet", detail: nil, control: spacer)
            hostList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: hostList.widthAnchor).isActive = true
            return
        }
        for (index, key) in keys.enumerated() {
            if index > 0 {
                hostList.addArrangedSubview(SettingsHairline())
                if let line = hostList.arrangedSubviews.last {
                    line.widthAnchor.constraint(equalTo: hostList.widthAnchor).isActive = true
                }
            }
            let remove = DepthButton(title: "Remove", kind: .secondary)
            styleSettingsButton(remove)
            remove.target = self
            remove.action = #selector(removeHost(_:))
            remove.identifier = NSUserInterfaceItemIdentifier(key)
            remove.setAccessibilityLabel("Remove icon for \(key)")
            let row = pane.makeRow(title: key, detail: nil, control: remove)
            hostList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: hostList.widthAnchor).isActive = true
        }
    }
}

@MainActor
class IconStyleChoice: NSButton {
    let style: AppIconStyle?
    var icon: NSImage?
    var picked = false {
        didSet { needsDisplay = true }
    }

    init(title: String, style: AppIconStyle?) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshAccessibility() {
        let suffix = picked ? ", selected" : ""
        setAccessibilityLabel("App icon: \(title)\(suffix)")
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width - 8, 58)
        let thumb = NSRect(x: bounds.midX - side / 2, y: bounds.height - side - 4, width: side, height: side)
        if let icon {
            // Uploads keep their aspect ratio. Fit inside the square instead of stretching.
            var fitted = thumb
            if icon.size.width > 0, icon.size.height > 0 {
                let scale = min(thumb.width / icon.size.width, thumb.height / icon.size.height)
                let width = icon.size.width * scale
                let height = icon.size.height * scale
                fitted = NSRect(x: thumb.midX - width / 2, y: thumb.midY - height / 2, width: width, height: height)
            }
            icon.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            Theme.card.setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 8, yRadius: 8).fill()
        }
        let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        if picked {
            Theme.accent.setStroke()
            ring.lineWidth = 2
        } else {
            Theme.line.setStroke()
            ring.lineWidth = SettingsContrast.lineWidth
        }
        ring.stroke()
        let ink = picked ? Theme.accent : Theme.text
        let font = Theme.font(size: 11, weight: .semibold)
        let rendered = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: ink
        ])
        let size = rendered.size()
        let label = NSRect(
            x: bounds.midX - size.width / 2,
            y: 2,
            width: size.width,
            height: size.height
        )
        rendered.draw(with: label, options: [.usesLineFragmentOrigin])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
