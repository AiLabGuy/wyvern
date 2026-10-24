// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// Rounded search field used by the bookmarks filter, the bookmarks search, and the new-tab field.
@MainActor
final class SearchField: NSView, NSTextFieldDelegate {
    let textField = NSTextField()
    var onTextChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var cornerRadius: CGFloat = MonoMetrics.urlRadius
    private let icon = GlyphView()
    private let trailingHost = NSView()
    private var trailingGap: NSLayoutConstraint?
    private var trailingZeroWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.glyph = .search
        icon.pointSize = 13
        icon.tint = Theme.mute
        icon.translatesAutoresizingMaskIntoConstraints = false

        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Theme.font(size: 13)
        textField.textColor = Theme.text
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submit)
        if let cell = textField.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        textField.translatesAutoresizingMaskIntoConstraints = false

        trailingHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(textField)
        addSubview(trailingHost)
        let gap = textField.trailingAnchor.constraint(equalTo: trailingHost.leadingAnchor, constant: 0)
        trailingGap = gap
        let zero = trailingHost.widthAnchor.constraint(equalToConstant: 0)
        trailingZeroWidth = zero
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MonoMetrics.urlPadding),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MonoMetrics.fieldGap),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            gap,
            trailingHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MonoMetrics.urlPadding),
            trailingHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            zero
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(iconSize: CGFloat, fontSize: CGFloat, placeholder: String, placeholderSize: CGFloat, radius: CGFloat) {
        cornerRadius = radius
        icon.pointSize = iconSize
        icon.constraints.first { $0.firstAttribute == .width }?.constant = iconSize
        icon.constraints.first { $0.firstAttribute == .height }?.constant = iconSize
        textField.font = Theme.font(size: fontSize)
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.mute,
            .font: Theme.font(size: placeholderSize)
        ])
        needsDisplay = true
    }

    func setTrailingView(_ view: NSView) {
        trailingHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        trailingHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: trailingHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: trailingHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: trailingHost.bottomAnchor)
        ])
        trailingGap?.constant = -MonoMetrics.fieldGap
        trailingZeroWidth?.isActive = false
    }

    override func draw(_ dirtyRect: NSRect) {
        FieldFrame.draw(in: bounds, radius: cornerRadius)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        textField.textColor = Theme.text
    }

    func controlTextDidChange(_ obj: Notification) {
        onTextChange?(textField.stringValue)
    }

    @objc private func submit() {
        BenchMarks.emit("return-keydown")
        onSubmit?(textField.stringValue)
    }
}

/// Draws the idle string only while the field editor is absent. Drawing both shows the old URL under typed text.
@MainActor
final class AddressTextFieldCell: NSTextFieldCell {
    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
        isScrollable = true
        sendsActionOnEndEditing = false
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
    }

    /// Stops `drawingRect` and `titleRect` from shifting twice when one calls the other.
    private var passingThrough = false

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        if passingThrough {
            return super.drawingRect(forBounds: rect)
        }
        passingThrough = true
        let base = super.drawingRect(forBounds: rect)
        passingThrough = false
        return verticallyCentered(base, bounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        if passingThrough {
            return super.titleRect(forBounds: rect)
        }
        passingThrough = true
        let base = super.titleRect(forBounds: rect)
        passingThrough = false
        return verticallyCentered(base, bounds: rect)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
        applyEditorTypography(textObj)
        centerEditor(textObj, boundsHeight: rect.height)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        applyEditorTypography(textObj)
        centerEditor(textObj, boundsHeight: rect.height)
    }

    /// The field editor must use the cell's font and color, matching the idle string.
    func applyEditorTypography(_ editor: NSText) {
        guard let view = editor as? NSTextView else { return }
        let font = self.font ?? view.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let color = self.textColor ?? Theme.text
        view.font = font
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes = [
            .font: font,
            .foregroundColor: color
        ]
        let length = (view.string as NSString).length
        if length > 0 {
            let range = NSRange(location: 0, length: length)
            view.setFont(font, range: range)
            view.setTextColor(color, range: range)
        }
    }

    /// `textContainerInset.height` is applied to both the top and the bottom of the field editor.
    func centerEditor(_ editor: NSText, boundsHeight: CGFloat) {
        guard let view = editor as? NSTextView else { return }
        let font = view.font ?? self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let extra = boundsHeight - font.boundingRectForFont.height
        let inset = max(0, extra / 2)
        if abs(view.textContainerInset.height - inset) > 0.25 {
            view.textContainerInset = NSSize(width: view.textContainerInset.width, height: inset)
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let field = controlView as? NSTextField, field.currentEditor() != nil {
            return
        }
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    /// Shift by half the spare height. `cellSize` is not used here; it calls back into this method.
    private func verticallyCentered(_ rect: NSRect, bounds: NSRect) -> NSRect {
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let extra = bounds.height - font.boundingRectForFont.height
        guard extra > 1 else { return rect }
        var shifted = rect
        shifted.origin.y += floor(extra / 2)
        return shifted
    }
}

/// Plain `NSTextField` with stock click handling. Reports focus directly:
/// `controlTextDidBeginEditing` arrives on the first keystroke, which is too late.
@MainActor
final class AddressTextField: NSTextField {
    var onDidBecomeFirstResponder: (() -> Void)?
    var onDidResignFirstResponder: (() -> Void)?
    /// Full URL while the visible idle string is only the styled host and tail.
    var idleAccessibilityValue: String?
    /// Timestamp of the mouse-down that made this field first responder. `NSWindow` may do that
    /// before it sends `mouseDown`, so "was the editor already up" alone cannot tell.
    private var focusClickTimestamp: TimeInterval?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// The field sits under the transparent title bar. A click on it must not start a window drag.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if let event = NSApp.currentEvent, event.type == .leftMouseDown {
                focusClickTimestamp = event.timestamp
            } else {
                focusClickTimestamp = nil
            }
            onDidBecomeFirstResponder?()
        }
        return accepted
    }

    /// Stock tracking first: AppKit makes the field first responder and the field editor tracks
    /// the click to mouse-up, placing the caret. A click that began editing then selects all.
    /// A later click while editing keeps the stock caret placement.
    /// A terminal command is not editable; that click must not open the field editor.
    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        let beginsEditing = currentEditor() == nil || focusClickTimestamp == event.timestamp
        super.mouseDown(with: event)
        focusClickTimestamp = nil
        guard beginsEditing else { return }
        if currentEditor() == nil {
            window?.makeFirstResponder(self)
        }
        selectAllAfterClick()
    }

    /// Selects the whole edit string now and once more on the next main-queue turn, in case
    /// tracking parks the caret late. The second pass is skipped if a key changed the string.
    func selectAllAfterClick() {
        guard let editor = currentEditor() else { return }
        editor.selectAll(nil)
        let text = editor.string
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let editor = self.currentEditor(), editor.string == text else { return }
                editor.selectAll(nil)
            }
        }
    }

    // No resignFirstResponder hook: an NSTextField resigns first responder to its field editor
    // immediately after it gains focus, so that callback would restore the idle string while
    // the person is editing. textDidEndEditing is the real end of editing.

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onDidResignFirstResponder?()
    }

    override func accessibilityValue() -> String? {
        if let editor = currentEditor() {
            return editor.string
        }
        if let idleAccessibilityValue {
            return idleAccessibilityValue
        }
        return stringValue
    }

    /// The field editor holds the selection while editing; report it, not the cell's.
    override func accessibilitySelectedText() -> String? {
        guard let editor = currentEditor() else { return nil }
        let range = editor.selectedRange
        let text = editor.string as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else {
            return nil
        }
        return text.substring(with: range)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let editor = currentEditor() else { return NSRange(location: 0, length: 0) }
        return editor.selectedRange
    }
}

/// Toolbar address field. One text field draws the idle host and muted tail, and edits the plain full URL.
@MainActor
final class AddressBarField: NSView, NSTextFieldDelegate {
    let textField = AddressTextField()
    var onSubmit: ((String) -> Void)?
    var onToggleStar: (() -> Void)?
    private let icon = GlyphView()
    private let braces = DevToolsBracesView()
    private let star = ToolButton()
    private let kvmBadge = KVMAddressBadgeView()
    private var textToStar: NSLayoutConstraint?
    private var textToBadge: NSLayoutConstraint?
    private var kvmBadgeWidth: NSLayoutConstraint?
    private var pageURL: URL?
    /// Source URL shown muted and read-only while a DevTools tab is focused.
    private var showingDevToolsSource = false
    /// Full command while a terminal tab is showing. Nil for a web address.
    private var commandText: String?
    /// Shell and directory shown in the field. The accessibility value stays `commandText`.
    private var commandCaption: String?
    private var editing = false
    /// True while the user is typing a URL. Pane switches keep that text until Esc or Return.
    var isEditingURL: Bool { editing }
    /// Return ends editing inside `onSubmit`. That callback must not rewrite `stringValue` before the typed text is submitted.
    private var suppressRestore = false
    private let placeholder = "Search or enter address"
    /// The address text font in every state (see `AddressTypography`). Return must not change it.
    static let addressFont: NSFont = {
        let spec = AddressTypography.text
        let weight = NSFont.Weight(rawValue: CGFloat(spec.weight))
        switch spec.design {
        case .monospaced:
            return Theme.mono(size: CGFloat(spec.size), weight: weight)
        case .system:
            return Theme.font(size: CGFloat(spec.size), weight: weight)
        }
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.glyph = .search
        icon.pointSize = MonoMetrics.lockIcon
        icon.tint = Theme.mute
        icon.translatesAutoresizingMaskIntoConstraints = false
        braces.pointSize = 14
        braces.isHidden = true
        braces.translatesAutoresizingMaskIntoConstraints = false

        textField.cell = AddressTextFieldCell(textCell: "")
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Self.addressFont
        textField.textColor = Theme.text
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.isScrollable = true
        if let cell = textField.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        textField.delegate = self
        textField.isEditable = true
        textField.isSelectable = true
        textField.allowsEditingTextAttributes = false
        textField.maximumNumberOfLines = 1
        textField.setAccessibilityElement(true)
        textField.setAccessibilityIdentifier("wyvern.address")
        textField.setAccessibilityLabel("Address and search")
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.onDidBecomeFirstResponder = { [weak self] in
            self?.handleFocusGain()
        }
        textField.onDidResignFirstResponder = { [weak self] in
            self?.handleFocusLoss()
        }
        setAccessibilityElement(false)
        applyPlaceholder()

        star.glyph = .star
        star.pointSize = MonoMetrics.starGlyph
        star.tint = Theme.mute
        star.cornerRadius = 0
        star.target = self
        star.action = #selector(starTapped)
        star.translatesAutoresizingMaskIntoConstraints = false

        kvmBadge.translatesAutoresizingMaskIntoConstraints = false
        kvmBadge.isHidden = true
        addSubview(textField)
        addSubview(icon)
        addSubview(braces)
        addSubview(star)
        addSubview(kvmBadge)
        let toStar = textField.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -MonoMetrics.fieldGap)
        let toBadge = textField.trailingAnchor.constraint(equalTo: kvmBadge.leadingAnchor, constant: -MonoMetrics.fieldGap)
        toBadge.isActive = false
        let badgeWidth = kvmBadge.widthAnchor.constraint(equalToConstant: 0)
        textToStar = toStar
        textToBadge = toBadge
        kvmBadgeWidth = badgeWidth
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MonoMetrics.urlPadding),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: MonoMetrics.lockIcon),
            icon.heightAnchor.constraint(equalToConstant: MonoMetrics.lockIcon),
            braces.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            braces.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            braces.widthAnchor.constraint(equalToConstant: 14),
            braces.heightAnchor.constraint(equalToConstant: 14),
            star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MonoMetrics.urlPadding),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: MonoMetrics.starHit),
            star.heightAnchor.constraint(equalToConstant: MonoMetrics.starHit),
            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MonoMetrics.fieldGap),
            toStar,
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            kvmBadge.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -4),
            kvmBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            kvmBadge.heightAnchor.constraint(equalToConstant: 18),
            badgeWidth
        ])
        applyDisplay()
    }

    /// KVM pill in the URL strip. Hidden for terminal tabs, DevTools, and sites that are not in the list.
    func setKVM(_ state: KVMAddressBadgeView.State) {
        kvmBadge.apply(state)
        let show = state != .off
        kvmBadge.isHidden = !show
        if show {
            textToStar?.isActive = false
            textToBadge?.isActive = true
        } else {
            textToBadge?.isActive = false
            textToStar?.isActive = true
        }
        kvmBadgeWidth?.constant = show ? kvmBadge.preferredWidth : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    // No hitTest override: the text field and the star are ordinary subviews, so AppKit's own
    // hit-testing gives each its click. Only the icon and padding reach this view.

    /// A click on the icon or the padding edits the field, as a click on its text does.
    /// A terminal command is display-only: padding must not select or edit it.
    override func mouseDown(with event: NSEvent) {
        guard commandText == nil, let window else { return }
        if textField.currentEditor() == nil {
            window.makeFirstResponder(textField)
        }
        textField.selectAllAfterClick()
    }

    func present(url: URL?, bookmarked: Bool, canBookmark: Bool, showsSecurityLock: Bool = true) {
        commandText = nil
        commandCaption = nil
        showingDevToolsSource = false
        braces.isHidden = true
        icon.isHidden = false
        setKVM(.off)
        pageURL = url
        textField.isEditable = true
        toolTip = nil
        textField.toolTip = nil
        star.tint = bookmarked ? Theme.accent : Theme.mute
        star.isEnabled = canBookmark
        star.setAccessibilityLabel(bookmarked ? "Remove Bookmark" : "Add Bookmark")
        // A lock on http, file, blob, or the load-failure document would claim a guarantee the page does not have.
        if url == nil {
            icon.isHidden = false
            icon.glyph = .search
        } else if showsSecurityLock && AddressSecurity.showsLock(url) {
            icon.isHidden = false
            icon.glyph = .lock
        } else {
            icon.isHidden = true
        }
        icon.tint = Theme.mute
        guard !editing else { return }
        applyDisplay()
    }

    /// Source URL while DevTools is focused. Muted, read-only, with the `{}` tile.
    /// The star still bookmarks that source page.
    func presentDevTools(url: URL?, bookmarked: Bool, canBookmark: Bool) {
        editing = false
        commandText = nil
        commandCaption = nil
        showingDevToolsSource = true
        pageURL = url
        textField.isEditable = false
        textField.isSelectable = true
        icon.isHidden = true
        braces.isHidden = false
        setKVM(.off)
        star.isEnabled = canBookmark
        star.tint = bookmarked ? Theme.accent : Theme.mute
        star.setAccessibilityLabel(bookmarked ? "Remove Bookmark" : "Add Bookmark")
        let raw = url?.absoluteString ?? ""
        setIdleFont(Self.addressFont)
        setIdleColor(Theme.mute)
        setIdleString(raw)
        textField.idleAccessibilityValue = raw.isEmpty ? nil : raw
        textField.toolTip = raw
        toolTip = raw
    }

    /// Shows a terminal tab. The visible caption is the shell and directory.
    /// The accessibility value, tooltip, and stored command stay the full command.
    func presentCommand(_ command: String) {
        presentCommand(command, caption: command)
    }

    func presentCommand(_ command: String, caption: String) {
        editing = false
        showingDevToolsSource = false
        braces.isHidden = true
        icon.isHidden = false
        commandText = command
        commandCaption = caption
        pageURL = nil
        setKVM(.off)
        textField.isEditable = false
        textField.isSelectable = true
        icon.isHidden = false
        icon.glyph = .terminal
        icon.tint = Theme.termGlyph
        star.isEnabled = false
        star.tint = Theme.mute
        star.setAccessibilityLabel("Add Bookmark")
        setIdleFont(Theme.mono(size: 12.5))
        setIdleColor(Theme.text)
        textField.idleAccessibilityValue = command
        setIdleString(caption)
        textField.toolTip = command
        toolTip = command
    }

    override func draw(_ dirtyRect: NSRect) {
        FieldFrame.draw(in: bounds, radius: MonoMetrics.urlRadius)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        applyPlaceholder()
        if editing {
            textField.textColor = Theme.text
            if let view = textField.currentEditor() as? NSTextView {
                view.textColor = Theme.text
                view.insertionPointColor = Theme.text
            }
        } else {
            applyDisplay()
        }
    }

    /// Return submits the field editor's string, then ends editing. Escape reverts. A click away only ends editing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            BenchMarks.emit("return-keydown")
            let typed = textView.string
            suppressRestore = true
            onSubmit?(typed)
            if editing {
                window?.makeFirstResponder(nil)
            }
            suppressRestore = false
            editing = false
            applyDisplay()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    @objc private func starTapped() {
        onToggleStar?()
    }

    private func handleFocusGain() {
        let alreadyEditing = editing
        editing = true
        if !alreadyEditing {
            showPlainEditingText()
        }
    }

    private func handleFocusLoss() {
        guard editing else { return }
        editing = false
        if suppressRestore {
            return
        }
        applyDisplay()
    }

    /// Plain full URL in the normal text color. The cell is updated only before the editor exists.
    /// Assigning `stringValue` while the editor is up can end the edit that just started.
    private func showPlainEditingText() {
        // One font for typing and for the committed URL, with or without a page URL.
        let font = Self.addressFont
        textField.font = font
        if let cell = textField.cell as? NSTextFieldCell {
            cell.font = font
        }
        textField.textColor = Theme.text
        let plain: String? = pageURL?.absoluteString
        if textField.currentEditor() == nil, let plain, textField.stringValue != plain {
            textField.stringValue = plain
        }
        guard let view = textField.currentEditor() as? NSTextView else { return }
        if let plain, view.string != plain {
            view.string = plain
        }
        applyEditorStyle(view)
    }

    /// One text color for the whole editor. The idle string uses mute for the tail; typed text must not.
    private func applyEditorStyle(_ view: NSTextView) {
        view.drawsBackground = false
        if let cell = textField.cell as? AddressTextFieldCell {
            cell.font = textField.font
            cell.textColor = textField.textColor
            cell.applyEditorTypography(view)
            cell.centerEditor(view, boundsHeight: textField.bounds.height)
        } else {
            let font = textField.font ?? Self.addressFont
            view.font = font
            view.textColor = Theme.text
            view.insertionPointColor = Theme.text
            view.typingAttributes = [
                .font: font,
                .foregroundColor: Theme.text
            ]
        }
    }

    private func applyPlaceholder() {
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.mute,
            .font: Theme.font(size: 13)
        ])
    }

    private func applyDisplay() {
        if showingDevToolsSource {
            presentDevTools(url: pageURL, bookmarked: star.tint == Theme.accent, canBookmark: star.isEnabled)
            return
        }
        if let command = commandText {
            setIdleFont(Theme.mono(size: 12.5))
            setIdleColor(Theme.text)
            textField.idleAccessibilityValue = command
            setIdleString(commandCaption ?? command)
            textField.toolTip = command
            toolTip = command
            icon.isHidden = false
            icon.glyph = .terminal
            icon.tint = Theme.termGlyph
            return
        }
        if let url = pageURL {
            let font = Self.addressFont
            setIdleFont(font)
            setIdleColor(Theme.text)
            textField.idleAccessibilityValue = url.absoluteString
            setIdleAttributed(Self.attributed(url, font: font))
        } else {
            setIdleFont(Self.addressFont)
            setIdleColor(Theme.text)
            textField.idleAccessibilityValue = nil
            setIdleString("")
        }
    }

    /// Assigning the same string still dirties the field and flashes the address text.
    private func setIdleString(_ value: String) {
        guard textField.stringValue != value else { return }
        textField.stringValue = value
    }

    private func setIdleAttributed(_ value: NSAttributedString) {
        guard textField.attributedStringValue.isEqual(value) == false else { return }
        textField.attributedStringValue = value
    }

    private func setIdleFont(_ font: NSFont) {
        guard textField.font?.isEqual(font) != true else { return }
        textField.font = font
    }

    private func setIdleColor(_ color: NSColor) {
        guard textField.textColor?.isEqual(color) != true else { return }
        textField.textColor = color
    }

    private static func attributed(_ url: URL, font: NSFont) -> NSAttributedString {
        let parts = AddressFormatting.parts(for: url)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: parts.primary, attributes: [
            .font: font,
            .foregroundColor: Theme.text,
            .paragraphStyle: style
        ])
        if !parts.secondary.isEmpty {
            result.append(NSAttributedString(string: parts.secondary, attributes: [
                .font: font,
                .foregroundColor: Theme.mute,
                .paragraphStyle: style
            ]))
        }
        return result
    }
}
