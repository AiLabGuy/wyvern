// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import App1Core
import AppKit

/// Fixed first-run window. Retained until it closes so its button targets stay alive.
@MainActor
final class FirstRunSetupController: NSWindowController, NSWindowDelegate {
    private static var lifetime: [FirstRunSetupController] = []

    static func retain(_ controller: FirstRunSetupController) {
        if !lifetime.contains(where: { $0 === controller }) {
            lifetime.append(controller)
        }
    }

    var onClose: (() -> Void)?
    private let bookmarks: BookmarkStore
    private let settings: SettingsStore
    private var step: Step = .welcome
    private var profiles: [(DetectedProfile, ImportPreview?, NSButton?)] = []
    private var importedCount: Int?
    private var didFinish = false
    /// True only after the Done step's primary button closes the window.
    private(set) var finishedOnDone = false
    private var positioningLights = false

    private let titleBand = NSView()
    private let body = NSView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let dots = StepDotsView()
    private let backButton = DepthButton(title: "Back", kind: .secondary)
    private let nextButton = DepthButton(title: "Get started", kind: .primary)
    private let skipButton = DepthButton(title: "Skip", kind: .ghost)

    private enum Step: Int, CaseIterable {
        case welcome = 0
        case importBrowsers
        case appearance
        case latency
        case done

        var shortName: String {
            switch self {
            case .welcome: return "Welcome"
            case .importBrowsers: return "Import"
            case .appearance: return "Appearance"
            case .latency: return "Network"
            case .done: return "Done"
            }
        }

        var pageIdentifier: String {
            switch self {
            case .welcome: return "app1.setup.welcome"
            case .importBrowsers: return "app1.setup.import"
            case .appearance: return "app1.setup.appearance"
            case .latency: return "app1.setup.latency"
            case .done: return "app1.setup.done"
            }
        }
    }

    init(bookmarks: BookmarkStore, settings: SettingsStore) {
        self.bookmarks = bookmarks
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.displayName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.win
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 600))
        let frameSize = window.frame.size
        window.minSize = frameSize
        window.maxSize = frameSize
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = 12
            content.layer?.masksToBounds = true
        }
        buildFrame()
        show(.welcome)
        window.setAccessibilityIdentifier("app1.setup.window")
        window.contentView?.setAccessibilityIdentifier("app1.setup.window")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        centerSetupLights()
    }

    func windowDidResize(_ notification: Notification) {
        centerSetupLights()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onClose?()
        Self.lifetime.removeAll { $0 === self }
    }

    private func buildFrame() {
        guard let content = window?.contentView else { return }
        let backdrop = SetupBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        titleBand.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = body
        body.translatesAutoresizingMaskIntoConstraints = false

        let footer = SetupFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.setAccessibilityIdentifier("app1.setup.back")
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.setAccessibilityIdentifier("app1.setup.skip")
        // Shares DepthButton's primary stops. Dark mode is #5A7BE6 over #4C6FE0 with white text.
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.keyEquivalent = "\r"
        nextButton.setAccessibilityIdentifier("app1.setup.next")

        dots.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = Theme.font(size: 11)
        stepLabel.textColor = Theme.mute
        stepLabel.setAccessibilityIdentifier("app1.setup.step")

        let indicator = NSStackView(views: [dots, stepLabel])
        indicator.orientation = .horizontal
        indicator.alignment = .centerY
        indicator.spacing = 8
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [skipButton, backButton, nextButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(backdrop)
        content.addSubview(titleBand)
        content.addSubview(scroll)
        content.addSubview(footer)
        footer.addSubview(indicator)
        footer.addSubview(buttons)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            titleBand.topAnchor.constraint(equalTo: content.topAnchor),
            titleBand.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleBand.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleBand.heightAnchor.constraint(equalToConstant: 38),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),

            scroll.topAnchor.constraint(equalTo: titleBand.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            indicator.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            indicator.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dots.widthAnchor.constraint(equalToConstant: 78),
            dots.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    private func show(_ step: Step) {
        let previous = body.subviews
        self.step = step
        let number = step.rawValue + 1
        stepLabel.stringValue = "Step \(number) of 5 · \(step.shortName)"
        stepLabel.setAccessibilityValue(step.shortName)
        dots.index = step.rawValue
        dots.needsDisplay = true
        backButton.isHidden = step == .welcome
        skipButton.isHidden = step != .importBrowsers
        switch step {
        case .welcome:
            nextButton.title = "Get started"
        case .done:
            nextButton.title = "Start browsing"
        default:
            nextButton.title = "Next"
        }
        nextButton.invalidateIntrinsicContentSize()
        let page = page(for: step)
        page.translatesAutoresizingMaskIntoConstraints = false
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce || previous.isEmpty {
            previous.forEach { $0.removeFromSuperview() }
            install(page)
        } else {
            page.alphaValue = 0
            install(page)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                page.animator().alphaValue = 1
                previous.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                Task { @MainActor in
                    previous.forEach { $0.removeFromSuperview() }
                }
            }
        }
    }

    private func install(_ page: NSView) {
        body.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            page.topAnchor.constraint(equalTo: body.topAnchor),
            page.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }

    private func page(for step: Step) -> NSView {
        switch step {
        case .welcome: return welcomePage()
        case .importBrowsers: return importPage()
        case .appearance: return appearancePage()
        case .latency: return latencyPage()
        case .done: return donePage()
        }
    }

    private func welcomePage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 48, bottom: 16, right: 48)
        stack.addArrangedSubview(iconView(side: 88, radius: 19))
        let title = headline("Welcome to \(AppInfo.displayName)", size: 28, tracking: true)
        title.setAccessibilityIdentifier(Step.welcome.pageIdentifier)
        stack.addArrangedSubview(title)
        let body = mute(
            "A small, fast browser that stays out of your way. Let's set up a few things. It takes under a minute.",
            size: 14,
            width: 440
        )
        body.alignment = .center
        stack.addArrangedSubview(body)
        let cards = NSStackView(views: [
            featureCard(title: "Bring bookmarks", detail: "From browsers you use", glyph: .bookmark),
            featureCard(title: "Your look", detail: "Light, dark or auto", glyph: .moon),
            featureCard(title: "Network health", detail: "Latency at a glance", glyph: .activity)
        ])
        cards.orientation = .horizontal
        cards.spacing = 10
        cards.alignment = .top
        stack.addArrangedSubview(cards)
        stack.setCustomSpacing(22, after: cards)
        stack.addArrangedSubview(footnote())
        return stack
    }

    private func importPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 48, bottom: 16, right: 48)
        stack.addArrangedSubview(iconView(side: 40, radius: 9))
        let title = headline("Import bookmarks", size: 22, tracking: false)
        title.setAccessibilityIdentifier(Step.importBrowsers.pageIdentifier)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        let intro = mute(
            "We found these browsers on this Mac. Choose which bookmarks to bring over. Nothing is uploaded.",
            size: 13,
            width: 640
        )
        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(16, after: intro)

        let found = BrowserDetector.scan(home: FileManager.default.homeDirectoryForCurrentUser)
        profiles = []
        if found.isEmpty {
            let empty = mute("No other browsers were found.", size: 13, width: 640)
            empty.setAccessibilityIdentifier("app1.setup.import.empty")
            stack.addArrangedSubview(empty)
            let count = countLine()
            stack.addArrangedSubview(count)
            return stack
        }
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        installCard(card)
        for (index, profile) in found.enumerated() {
            if index > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                card.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            }
            if profile.browser == .safari || profile.needsPermission {
                let row = infoRow("\(profile.browser.displayName) — needs permission")
                if profile.browser == .safari || profile.needsPermission {
                    row.setAccessibilityIdentifier("app1.setup.safari")
                }
                card.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
                profiles.append((profile, nil, nil))
                continue
            }
            let preview = BrowserDetector.preview(profile) ?? ImportPreview(
                profile: profile,
                bookmarkCount: 0,
                folderCount: 0,
                nodes: []
            )
            let box = SetupCheck()
            box.state = .on
            box.target = self
            box.action = #selector(selectionChanged)
            box.setAccessibilityIdentifier("app1.setup.browser.\(index)")
            let row = browserRow(name: profile.browser.displayName, count: preview.bookmarkCount, check: box)
            card.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            profiles.append((profile, preview, box))
        }
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96).isActive = true
        let count = countLine()
        stack.setCustomSpacing(10, after: card)
        stack.addArrangedSubview(count)
        selectionChanged()
        return stack
    }

    private func appearancePage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 48, bottom: 16, right: 48)
        stack.addArrangedSubview(iconView(side: 40, radius: 9))
        let title = headline("Light or dark?", size: 22, tracking: false)
        title.setAccessibilityIdentifier(Step.appearance.pageIdentifier)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        let intro = mute("You can change this any time in Settings → Appearance.", size: 13, width: 640)
        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(24, after: intro)
        let choices = NSStackView(views: [
            appearanceChoice("Light", preference: .light, id: "app1.setup.appearance.light"),
            appearanceChoice("Dark", preference: .dark, id: "app1.setup.appearance.dark"),
            appearanceChoice("Match System", preference: .system, id: "app1.setup.appearance.system")
        ])
        choices.orientation = .horizontal
        choices.spacing = 18
        choices.distribution = .fillEqually
        stack.addArrangedSubview(choices)
        choices.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96).isActive = true
        return stack
    }

    private func latencyPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 48, bottom: 16, right: 48)
        stack.addArrangedSubview(iconView(side: 40, radius: 9))
        let title = headline("Show the latency badge?", size: 22, tracking: false)
        title.setAccessibilityIdentifier(Step.latency.pageIdentifier)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        let intro = mute(
            "A small badge in the toolbar shows how quickly the current site responds. Click it for details.",
            size: 13,
            width: 640
        )
        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(20, after: intro)

        let toggle = SetupSwitch()
        toggle.state = settings.settings.netHealthEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(latencyToggled(_:))
        toggle.setAccessibilityIdentifier("app1.setup.latency.toggle")
        let name = NSTextField(labelWithString: "Show network badge in toolbar")
        name.font = Theme.font(size: 13, weight: .semibold)
        name.textColor = Theme.text
        let detail = mute("Measures only the site in your current tab. No data leaves this Mac.", size: 12, width: 480)
        let words = NSStackView(views: [name, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        let row = cardRow(views: [words, toggle])
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96).isActive = true

        let previewLabel = NSTextField(labelWithString: "PREVIEW")
        previewLabel.font = Theme.font(size: 11, weight: .semibold)
        previewLabel.textColor = Theme.mute
        stack.setCustomSpacing(18, after: row)
        stack.addArrangedSubview(previewLabel)
        stack.setCustomSpacing(8, after: previewLabel)
        stack.addArrangedSubview(networkPreview())
        return stack
    }

    private func donePage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 48, bottom: 16, right: 48)
        let icon = iconView(side: 88, radius: 19)
        let badge = CheckBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 34),
            badge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4)
        ])
        stack.addArrangedSubview(icon)
        let title = headline("You're all set", size: 26, tracking: false)
        title.alignment = .center
        title.setAccessibilityIdentifier(Step.done.pageIdentifier)
        stack.addArrangedSubview(title)
        let summary = mute(doneSummary(), size: 14, width: 440)
        summary.alignment = .center
        stack.addArrangedSubview(summary)
        let chips = NSStackView(views: [
            chip("⌘L", caption: "address bar"),
            chip("⌘T", caption: "new tab"),
            chip("⌘W", caption: "close tab")
        ])
        chips.orientation = .horizontal
        chips.spacing = 16
        chips.alignment = .centerY
        stack.addArrangedSubview(chips)
        return stack
    }

    private func doneSummary() -> String {
        let imported: String
        if let importedCount, importedCount > 0 {
            imported = "\(grouped(importedCount)) bookmarks imported"
        } else {
            imported = "No bookmarks imported"
        }
        let look: String
        switch settings.settings.appearance {
        case .light: look = "Light appearance"
        case .dark: look = "Dark appearance"
        case .system: look = "Match System appearance"
        }
        let badge = settings.settings.netHealthEnabled ? "Network badge on" : "Network badge off"
        return "\(imported) · \(look) · \(badge)"
    }

    private func iconView(side: CGFloat, radius: CGFloat) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = radius
        icon.layer?.masksToBounds = true
        icon.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.shadowBlurRadius = 24
            return shadow
        }()
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: side),
            icon.heightAnchor.constraint(equalToConstant: side)
        ])
        return icon
    }

    private func headline(_ text: String, size: CGFloat, tracking: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.font(size: size, weight: .bold)
        label.textColor = Theme.text
        if tracking {
            let styled = NSMutableAttributedString(string: text)
            styled.addAttributes([
                .font: Theme.font(size: size, weight: .bold),
                .foregroundColor: Theme.text,
                .kern: -0.02 * size
            ], range: NSRange(location: 0, length: (text as NSString).length))
            label.attributedStringValue = styled
        }
        return label
    }

    private func mute(_ text: String, size: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Theme.font(size: size)
        label.textColor = Theme.mute
        label.preferredMaxLayoutWidth = width
        return label
    }

    private func footnote() -> NSView {
        let wrap = NSView()
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: AppInfo.trademarkFootnote)
        label.font = Theme.font(size: 10.5)
        label.textColor = Theme.mute
        label.alignment = .center
        label.preferredMaxLayoutWidth = 560
        label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(rule)
        wrap.addSubview(label)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            rule.topAnchor.constraint(equalTo: wrap.topAnchor),
            rule.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            label.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
        return wrap
    }

    private func featureCard(title: String, detail: String, glyph: IconGlyph) -> NSView {
        let card = NSView()
        installCard(card)
        let mark = GlyphView()
        mark.glyph = glyph
        mark.tint = Theme.accent
        mark.pointSize = 18
        mark.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = Theme.font(size: 12.5, weight: .semibold)
        name.textColor = Theme.text
        let line = NSTextField(labelWithString: detail)
        line.font = Theme.font(size: 11.5)
        line.textColor = Theme.mute
        let words = NSStackView(views: [name, line])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(mark)
        card.addSubview(words)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 170),
            mark.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            mark.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            mark.widthAnchor.constraint(equalToConstant: 18),
            mark.heightAnchor.constraint(equalToConstant: 18),
            words.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            words.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            words.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 8),
            words.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        return card
    }

    private func browserRow(name: String, count: Int, check: NSButton) -> NSView {
        let letter = LetterTile(letter: String(name.prefix(1)).uppercased())
        let title = NSTextField(labelWithString: "\(name) — \(grouped(count)) bookmarks")
        title.font = Theme.font(size: 13, weight: .semibold)
        title.textColor = Theme.text
        let status = NSTextField(labelWithString: "Selected")
        status.font = Theme.font(size: 12)
        status.textColor = Theme.mute
        status.tag = 70
        let spacer = NSView()
        let row = NSStackView(views: [check, letter, title, spacer, status])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return row
    }

    private func infoRow(_ text: String) -> NSView {
        let letter = LetterTile(letter: String(text.prefix(1)).uppercased())
        let title = NSTextField(labelWithString: text)
        title.font = Theme.font(size: 13)
        title.textColor = Theme.text
        let row = NSStackView(views: [letter, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return row
    }

    private func countLine() -> NSTextField {
        let label = mute("", size: 11.5, width: 640)
        label.tag = 71
        label.stringValue = selectionSentence()
        return label
    }

    private func selectionSentence() -> String {
        let total = profiles.reduce(0) { partial, entry in
            guard let preview = entry.1, entry.2?.state == .on else { return partial }
            return partial + preview.bookmarkCount
        }
        return "\(grouped(total)) bookmarks selected · Duplicates are merged automatically. You can import later from Settings → Bookmarks."
    }

    private func appearanceChoice(_ title: String, preference: AppearancePreference, id: String) -> NSButton {
        let button = AppearanceChoice(title: title, preference: preference)
        button.target = self
        button.action = #selector(appearancePicked(_:))
        button.tag = preferenceTag(preference)
        button.state = settings.settings.appearance == preference ? .on : .off
        button.setAccessibilityIdentifier(id)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 148).isActive = true
        return button
    }

    private func cardRow(views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        installCard(row)
        return row
    }

    private func networkPreview() -> NSView {
        let host = NSTextField(labelWithString: "example.com/")
        host.font = Theme.mono(size: 12)
        host.textColor = Theme.text
        let badge = NSTextField(labelWithString: "● 38 ms")
        badge.font = Theme.mono(size: 9.5, weight: .semibold)
        let good = HealthState.good.presentation
        badge.textColor = Theme.color(
            hex: AppearanceController.currentName() == "dark" ? good.darkHex : good.lightHex
        )
        let legend = NSTextField(wrappingLabelWithString: "● Good <80 ms\n▲ Fair 80–250 ms\n✕ Poor >250 ms")
        legend.font = Theme.font(size: 11)
        legend.textColor = Theme.mute
        legend.alignment = .right
        let spacer = NSView()
        let row = NSStackView(views: [host, badge, spacer, legend])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        installCard(row)
        return row
    }

    private func chip(_ keys: String, caption: String) -> NSView {
        let key = NSTextField(labelWithString: keys)
        key.font = Theme.mono(size: 12)
        key.textColor = Theme.text
        key.alignment = .center
        let keyWrap = NSView()
        installCard(keyWrap, radius: 5)
        key.translatesAutoresizingMaskIntoConstraints = false
        keyWrap.addSubview(key)
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: keyWrap.leadingAnchor, constant: 6),
            key.trailingAnchor.constraint(equalTo: keyWrap.trailingAnchor, constant: -6),
            key.topAnchor.constraint(equalTo: keyWrap.topAnchor, constant: 3),
            key.bottomAnchor.constraint(equalTo: keyWrap.bottomAnchor, constant: -3)
        ])
        let word = NSTextField(labelWithString: caption)
        word.font = Theme.font(size: 12)
        word.textColor = Theme.mute
        let row = NSStackView(views: [keyWrap, word])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func installCard(_ view: NSView, radius: CGFloat = 10) {
        let fill = CardFill()
        fill.radius = radius
        fill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fill.topAnchor.constraint(equalTo: view.topAnchor),
            fill.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func preferenceTag(_ preference: AppearancePreference) -> Int {
        switch preference {
        case .system: return 1
        case .light: return 2
        case .dark: return 3
        }
    }

    private func preference(for tag: Int) -> AppearancePreference {
        switch tag {
        case 1: return .system
        case 2: return .light
        default: return .dark
        }
    }

    @objc private func selectionChanged() {
        let sentence = selectionSentence()
        func walk(_ view: NSView) {
            if let label = view as? NSTextField, label.tag == 71 {
                label.stringValue = sentence
            }
            if let row = view as? NSStackView {
                let checks = row.arrangedSubviews.compactMap { $0 as? SetupCheck }
                let status = row.arrangedSubviews.compactMap { $0 as? NSTextField }.first { $0.tag == 70 }
                if let check = checks.first {
                    status?.stringValue = check.state == .on ? "Selected" : "Not selected"
                }
            }
            view.subviews.forEach(walk)
        }
        walk(body)
    }

    @objc private func appearancePicked(_ sender: NSButton) {
        let preference = preference(for: sender.tag)
        settings.update { $0.appearance = preference }
        AppearanceController.apply(preference)
        NotificationCenter.default.post(name: .app1SettingsDidChange, object: settings)
        func walk(_ view: NSView) {
            if let choice = view as? AppearanceChoice {
                choice.state = choice.tag == sender.tag ? .on : .off
                choice.needsDisplay = true
            }
            view.subviews.forEach(walk)
        }
        walk(body)
    }

    @objc private func latencyToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        settings.update { $0.netHealthEnabled = enabled }
        NotificationCenter.default.post(name: .app1SettingsDidChange, object: settings)
        sender.needsDisplay = true
    }

    @objc private func backTapped() {
        switch step {
        case .welcome:
            break
        case .importBrowsers:
            show(.welcome)
        case .appearance:
            show(.importBrowsers)
        case .latency:
            show(.appearance)
        case .done:
            show(.latency)
        }
    }

    @objc private func nextTapped() {
        switch step {
        case .welcome:
            show(.importBrowsers)
        case .importBrowsers:
            let pending = profiles.compactMap { entry -> ImportPreview? in
                guard let preview = entry.1, entry.2?.state == .on else { return nil }
                return preview
            }
            if pending.isEmpty {
                importedCount = 0
            } else {
                let counts = BookmarkImportSheetController.performConfirmedImport(previews: pending, store: bookmarks)
                importedCount = counts.added
            }
            show(.appearance)
        case .appearance:
            show(.latency)
        case .latency:
            show(.done)
        case .done:
            finishedOnDone = true
            window?.close()
        }
    }

    @objc private func skipTapped() {
        window?.close()
    }

    /// Centers system buttons in the 38-point title band. Does not retag them; the main window owns those identifiers.
    private func centerSetupLights() {
        guard !positioningLights, let window else { return }
        let close = window.standardWindowButton(.closeButton)
        let miniaturize = window.standardWindowButton(.miniaturizeButton)
        let zoom = window.standardWindowButton(.zoomButton)
        let fullscreen = window.styleMask.contains(.fullScreen)
        let titled = window.styleMask.contains(.titled)
        let buttonsHidden = close?.isHidden == true || close?.superview?.isHidden == true
        if close == nil || fullscreen || !titled || buttonsHidden {
            return
        }
        guard let close else { return }
        positioningLights = true
        defer { positioningLights = false }
        let band = titleBand.convert(titleBand.bounds, to: nil)
        guard band.height > 2 else { return }
        let buttons = [close, miniaturize, zoom].compactMap { $0 }
        var seen: [NSView] = []
        for button in buttons {
            guard let host = button.superview else { continue }
            if seen.contains(where: { $0 === host }) { continue }
            seen.append(host)
            let buttonInWindow = button.convert(button.bounds, to: nil)
            let delta = band.midY - buttonInWindow.midY
            guard abs(delta) > 0.5, let parent = host.superview else { continue }
            let originInWindow = parent.convert(host.frame.origin, to: nil)
            let moved = NSPoint(x: originInWindow.x, y: originInWindow.y + delta)
            host.setFrameOrigin(parent.convert(moved, from: nil))
        }
    }
}

@MainActor
private final class SetupBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.fillGradient(top: Theme.win, bottom: Theme.page, path: NSBezierPath(rect: bounds))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class CardFill: NSView {
    var radius: CGFloat = 10

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Theme.card.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SetupFooter: NSView {
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
private final class StepDotsView: NSView {
    var index = 0

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for dot in 0..<5 {
            let width: CGFloat = dot == index ? 22 : 8
            let rect = NSRect(x: x, y: 0, width: width, height: 8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if dot <= index {
                Theme.accent.setFill()
            } else {
                Theme.line.setFill()
            }
            path.fill()
            x += width + 6
        }
    }
}

@MainActor
private final class SetupCheck: SettingsToggle {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.switch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if state == .on {
            Theme.accentFill.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY + 0.5))
            check.line(to: NSPoint(x: box.midX - 1, y: box.minY + 4))
            check.line(to: NSPoint(x: box.maxX - 3, y: box.maxY - 4))
            NSColor.white.setStroke()
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        } else {
            Theme.card.setFill()
            path.fill()
            Theme.fieldLine.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

@MainActor
private final class SetupSwitch: SettingsToggle {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.switch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        if state == .on {
            Theme.accentFill.setFill()
        } else {
            Theme.line.setFill()
        }
        path.fill()
        let knob = NSRect(x: state == .on ? 18 : 2, y: 2, width: 18, height: 18)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}

@MainActor
private final class LetterTile: NSView {
    private let letter: String

    init(letter: String) {
        self.letter = letter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.field.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = Theme.font(size: 13, weight: .bold)
        let text = NSAttributedString(string: letter, attributes: [
            .font: font,
            .foregroundColor: Theme.text
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

@MainActor
private final class AppearanceChoice: SettingsRadio {
    let preference: AppearancePreference

    init(title: String, preference: AppearancePreference) {
        self.preference = preference
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.radio)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let thumb = NSRect(x: 1.5, y: 26, width: bounds.width - 3, height: 120)
        let page: NSColor
        let bar: NSColor
        switch preference {
        case .light:
            page = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            bar = NSColor(srgbRed: 0.925, green: 0.933, blue: 0.945, alpha: 1)
        case .dark:
            page = Theme.color(hex: "#17181A")
            bar = Theme.color(hex: "#26282C")
        case .system:
            page = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            bar = NSColor(srgbRed: 0.925, green: 0.933, blue: 0.945, alpha: 1)
        }
        let clip = NSBezierPath(roundedRect: thumb, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if preference == .system {
            page.setFill()
            NSRect(x: thumb.minX, y: thumb.minY, width: thumb.width / 2, height: thumb.height).fill()
            Theme.color(hex: "#17181A").setFill()
            NSRect(x: thumb.midX, y: thumb.minY, width: thumb.width / 2, height: thumb.height).fill()
        } else {
            page.setFill()
            thumb.fill()
        }
        bar.setFill()
        NSRect(x: thumb.minX, y: thumb.maxY - 16, width: thumb.width, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: thumb, xRadius: 10, yRadius: 10)
        if state == .on {
            Theme.accent.setStroke()
            ring.lineWidth = 2.5
        } else {
            Theme.line.setStroke()
            ring.lineWidth = 1
        }
        ring.stroke()
        let font = Theme.font(size: 12, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: Theme.text
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 4))
    }
}

@MainActor
private final class CheckBadge: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        Theme.accentFill.setFill()
        path.fill()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: bounds.minX + 9, y: bounds.midY - 1))
        check.line(to: NSPoint(x: bounds.midX - 1, y: bounds.minY + 10))
        check.line(to: NSPoint(x: bounds.maxX - 8, y: bounds.maxY - 11))
        NSColor.white.setStroke()
        check.lineWidth = 2.2
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }
}
