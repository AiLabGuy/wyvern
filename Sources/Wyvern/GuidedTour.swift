// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore

/// Copy for the coach marks. Network health uses the same limits, labels, and probe names as the badge.
enum GuidedTourCopy {
    static let address = "Type a URL or search."
    static let tabs = "Web tabs and terminal tabs live together. Use Ctrl+Tab or Ctrl+~ to switch, and Cmd+Shift+A to search tabs."
    static let terminal = "The new-tab button opens a web tab. Its menu, and File → New Terminal Tab, open a terminal bookmark in a tab on this strip."
    static let bookmarks = "Open saved bookmarks. The star in the address bar adds the current page."

    static func settings() -> String {
        "Appearance, search, bookmarks, network health, and terminal bookmarks are in Settings. Choose Settings… in the \(AppInfo.displayName) menu, or press ⌘,."
    }

    /// Badge and Trace wording from `NetworkHealthViews` and the network-health core.
    static func networkHealth() -> String {
        let good = HealthLimits.goodUpperMilliseconds
        let fair = HealthLimits.fairUpperMilliseconds
        let loss = whole(HealthLimits.lossPoorPercent)
        let jitter = HealthLimits.jitterPoorMilliseconds
        let window = Int(HealthLimits.windowDuration)
        let silence = Int(HealthLimits.offlineSilence)
        let samples = HealthLimits.samplesToCommit
        let idle = HealthState.unknown.label
        let icmp = ProbeKind.icmp.displayName
        let httpsProbe = ProbeKind.tcp(port: 443).displayName
        let httpProbe = ProbeKind.tcp(port: 80).displayName
        return "Live connection health for this site: latency and status at a glance. Click for details; Trace maps the network path to the site. "
            + "The badge reads \(idle), \(HealthState.good.label), \(HealthState.fair.label), \(HealthState.poor.label), or \(HealthState.offline.label) from the last \(window) seconds. "
            + "Good is a median under \(good) ms, with loss at or under \(loss)% and jitter at or under \(jitter) ms. "
            + "Fair is \(good)–\(fair) ms with those same limits. "
            + "Poor is over \(fair) ms, or loss over \(loss)%, or jitter over \(jitter) ms. "
            + "Offline means no successful reply for \(silence) seconds, or the path reports no route. \(idle) waits until \(samples) samples agree. "
            + "The panel shows median latency, Host, IP, Protocol, Jitter, Loss, Hops, and Probe (\(icmp), \(httpsProbe), or \(httpProbe)). "
            + "Trace lists each hop's ttl, IP, and round-trip time, or shows Trace unavailable or Trace cancelled."
    }

    private static func whole(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}

struct GuidedTourStep {
    var id: String
    var title: String
    var message: String
    var anchor: () -> NSView?
    /// Settings is a menu command. The anchor only decides whether the window is on screen.
    var pointsAtTop = false
}

/// Full-window layer that draws a ring and a callout. Clicks pass through except on the bubble.
@MainActor
final class GuidedTourOverlay: NSView {
    var onFinish: (() -> Void)?

    private let steps: [GuidedTourStep]
    private let callout = TourCalloutView()
    private var currentID: String?
    private var keyMonitor: Any?
    private var refreshing = false
    private var ended = false
    private var ring: NSRect?

    init(steps: [GuidedTourStep]) {
        self.steps = steps
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        setAccessibilityElement(false)
        callout.translatesAutoresizingMaskIntoConstraints = true
        callout.isHidden = true
        callout.onNext = { [weak self] in self?.advance() }
        callout.onBack = { [weak self] in self?.retreat() }
        callout.onSkip = { [weak self] in self?.end() }
        addSubview(callout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func start() {
        installMonitor()
        currentID = nil
        refresh()
    }

    func restart() {
        start()
    }

    func refresh() {
        guard !ended, !refreshing else { return }
        guard bounds.width > 40, bounds.height > 40 else {
            callout.isHidden = true
            if ring != nil {
                ring = nil
                needsDisplay = true
            }
            return
        }
        refreshing = true
        defer { refreshing = false }
        let visible = visibleSteps()
        guard !visible.isEmpty else {
            callout.isHidden = true
            ring = nil
            needsDisplay = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.ended, self.visibleSteps().isEmpty else { return }
                self.end()
            }
            return
        }
        let index = resolvedIndex(in: visible)
        let step = visible[index]
        currentID = step.id
        callout.show(
            title: step.title,
            message: step.message,
            index: index,
            count: visible.count
        )
        place(step)
        callout.isHidden = false
        callout.setAccessibilityValue("Step \(index + 1) of \(visible.count): \(step.title)")
    }

    func end() {
        guard !ended else { return }
        ended = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        callout.isHidden = true
        ring = nil
        let finish = onFinish
        onFinish = nil
        // Drop the controller's reference before leaving the hierarchy. Layout during
        // removal would otherwise see the overlay and put it back.
        finish?()
        removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !callout.isHidden, callout.frame.contains(local) else { return nil }
        return callout.hitTest(local)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ring else { return }
        let rect = ring.insetBy(dx: -4, dy: -4)
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        Theme.accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        callout.needsDisplay = true
    }

    override var isOpaque: Bool { false }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleKey(event)
            }
        }
    }

    /// Escape ends the tour. Modified Escape and other windows keep the event.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !ended, event.keyCode == 53 else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return event
        }
        guard event.window === window else { return event }
        if window?.attachedSheet != nil || NSApp.modalWindow != nil { return event }
        if NSApp.mainMenu?.highlightedItem != nil { return event }
        // Removing the monitor inside its own callback is unsafe. End on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.end()
        }
        return nil
    }

    private func advance() {
        let visible = visibleSteps()
        guard !visible.isEmpty else {
            end()
            return
        }
        let index = resolvedIndex(in: visible)
        if index + 1 >= visible.count {
            end()
            return
        }
        currentID = visible[index + 1].id
        refresh()
    }

    private func retreat() {
        let visible = visibleSteps()
        let index = resolvedIndex(in: visible)
        guard index > 0 else { return }
        currentID = visible[index - 1].id
        refresh()
    }

    private func visibleSteps() -> [GuidedTourStep] {
        steps.filter { step in
            isAnchorVisible(step.anchor())
        }
    }

    private func resolvedIndex(in visible: [GuidedTourStep]) -> Int {
        guard let currentID else { return 0 }
        if let found = visible.firstIndex(where: { $0.id == currentID }) {
            return found
        }
        guard let original = steps.firstIndex(where: { $0.id == currentID }) else { return 0 }
        if let later = steps.suffix(from: steps.index(after: original)).first(where: { step in
            visible.contains(where: { $0.id == step.id })
        }), let found = visible.firstIndex(where: { $0.id == later.id }) {
            return found
        }
        return max(visible.count - 1, 0)
    }

    private func isAnchorVisible(_ view: NSView?) -> Bool {
        guard let view else { return false }
        guard let viewWindow = view.window, viewWindow === window else { return false }
        if view.isHiddenOrHasHiddenAncestor { return false }
        if view.visibleRect.width < 1 || view.visibleRect.height < 1 { return false }
        let rect = view.convert(view.visibleRect, to: self)
        return bounds.intersects(rect)
    }

    private func place(_ step: GuidedTourStep) {
        let anchor = step.anchor()
        let aim: NSRect
        let nextRing: NSRect?
        if step.pointsAtTop {
            aim = NSRect(x: bounds.midX - 1, y: bounds.maxY - 1, width: 2, height: 1)
            nextRing = nil
        } else if let anchor {
            let full = anchor.convert(anchor.bounds, to: self)
            aim = full
            let clipped = full.intersection(bounds.insetBy(dx: 1, dy: 1))
            nextRing = clipped.isNull || clipped.width < 2 || clipped.height < 2 ? nil : clipped
        } else {
            aim = NSRect(x: bounds.midX - 1, y: bounds.midY, width: 2, height: 2)
            nextRing = nil
        }
        let edge: TourBeakEdge
        if step.pointsAtTop {
            edge = .up
        } else {
            let rough = callout.measuredSize(beakEdge: .up).height
            edge = aim.minY - 10 - rough < 12 ? .down : .up
        }
        let size = callout.measuredSize(beakEdge: edge)
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        var origin = NSPoint(x: aim.midX - size.width / 2, y: margin)
        if step.pointsAtTop {
            origin.y = bounds.height - MonoMetrics.backdropHeight - gap - size.height
        } else if edge == .up {
            origin.y = aim.minY - gap - size.height
        } else {
            origin.y = aim.maxY + gap
        }
        origin.x = min(max(margin, origin.x), max(margin, bounds.width - margin - size.width))
        origin.y = min(max(margin, origin.y), max(margin, bounds.height - margin - size.height))
        var beakX = aim.midX - origin.x
        beakX = min(max(22, beakX), max(22, size.width - 22))
        let frame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        if framesDiffer(callout.frame, frame) {
            callout.frame = frame
        }
        callout.setBeak(edge: edge, x: beakX)
        if ring != nextRing {
            ring = nextRing
            needsDisplay = true
        }
    }

    private func framesDiffer(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) > 0.5
            || abs(lhs.minY - rhs.minY) > 0.5
            || abs(lhs.width - rhs.width) > 0.5
            || abs(lhs.height - rhs.height) > 0.5
    }
}

private enum TourBeakEdge {
    case up
    case down
}

private enum TourMetrics {
    static let bubbleWidth: CGFloat = 360
    static let pad: CGFloat = 16
    static let beak: CGFloat = 9
    static var contentWidth: CGFloat { bubbleWidth - pad * 2 }
}

@MainActor
private final class TourCalloutView: NSView {
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let dots = TourDotsView()
    private let skipButton = DepthButton(title: "Skip", kind: .ghost)
    private let backButton = DepthButton(title: "Back", kind: .secondary)
    private let nextButton = DepthButton(title: "Next", kind: .primary)
    private var beakEdge: TourBeakEdge = .up
    private var beakX: CGFloat = 40
    private var stackTop: NSLayoutConstraint?
    private var stackBottom: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("wyvern.tour")
        setAccessibilityLabel("Tour")

        titleField.font = Theme.font(size: 14, weight: .semibold)
        titleField.textColor = Theme.text
        titleField.setAccessibilityIdentifier("wyvern.tour.title")
        bodyField.font = Theme.font(size: 13)
        bodyField.textColor = Theme.mute
        bodyField.preferredMaxLayoutWidth = TourMetrics.contentWidth
        bodyField.setAccessibilityIdentifier("wyvern.tour.body")

        dots.setAccessibilityIdentifier("wyvern.tour.dots")
        dots.setAccessibilityLabel("Tour progress")

        skipButton.controlHeight = 32
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.setAccessibilityIdentifier("wyvern.tour.skip")
        backButton.controlHeight = 32
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.setAccessibilityIdentifier("wyvern.tour.back")
        nextButton.controlHeight = 32
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.setAccessibilityIdentifier("wyvern.tour.next")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [dots, spacer, skipButton, backButton, nextButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleField, bodyField, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let top = stack.topAnchor.constraint(equalTo: topAnchor, constant: TourMetrics.pad + TourMetrics.beak)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TourMetrics.pad)
        stackTop = top
        stackBottom = bottom
        NSLayoutConstraint.activate([
            top,
            bottom,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TourMetrics.pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TourMetrics.pad),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        dots.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        skipButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        backButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nextButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        frame = NSRect(x: 0, y: 0, width: TourMetrics.bubbleWidth, height: 120)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, message: String, index: Int, count: Int) {
        let nextTitle = index >= count - 1 ? "Done" : "Next"
        let changed = titleField.stringValue != title
            || bodyField.stringValue != message
            || dots.index != index
            || dots.count != count
            || nextButton.title != nextTitle
            || backButton.isEnabled != (index > 0)
        guard changed else { return }
        titleField.stringValue = title
        bodyField.stringValue = message
        bodyField.preferredMaxLayoutWidth = TourMetrics.contentWidth
        dots.count = count
        dots.index = index
        dots.setAccessibilityValue("Step \(index + 1) of \(count)")
        backButton.isEnabled = index > 0
        nextButton.title = nextTitle
        nextButton.setAccessibilityLabel(nextTitle)
        nextButton.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
    }

    func setBeak(edge: TourBeakEdge, x: CGFloat) {
        let edgeChanged = beakEdge != edge
        let xChanged = abs(beakX - x) > 0.5
        guard edgeChanged || xChanged else { return }
        beakEdge = edge
        beakX = x
        if edgeChanged {
            let pad = TourMetrics.pad
            let beak = TourMetrics.beak
            stackTop?.constant = edge == .up ? pad + beak : pad
            stackBottom?.constant = edge == .down ? -(pad + beak) : -pad
        }
        needsDisplay = true
    }

    /// Height follows the text. The beak does not change it: one side gains the same inset the other loses.
    func measuredSize(beakEdge edge: TourBeakEdge) -> NSSize {
        _ = edge
        let width = TourMetrics.contentWidth
        bodyField.preferredMaxLayoutWidth = width
        let titleHeight = textHeight(titleField.stringValue, font: titleField.font, width: width)
        // The field is a little taller than the string's bounding rect. Extra room keeps the last line inside the bubble.
        let bodyHeight = textHeight(bodyField.stringValue, font: bodyField.font, width: max(1, width - 2)) + 6
        let footerHeight = max(nextButton.intrinsicContentSize.height, 32)
        let stackHeight = titleHeight + 8 + bodyHeight + 8 + footerHeight
        let height = max(88, stackHeight + TourMetrics.pad * 2 + TourMetrics.beak + 4)
        return NSSize(width: TourMetrics.bubbleWidth, height: height)
    }

    private func textHeight(_ string: String, font: NSFont?, width: CGFloat) -> CGFloat {
        let font = font ?? Theme.font(size: 13)
        let rect = (string as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: 4_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(ceil(rect.height), ceil(font.boundingRectForFont.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bubbleContains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bodyRect()
        let rounded = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
        Theme.card.setFill()
        rounded.fill()
        Theme.line.setStroke()
        rounded.lineWidth = 1
        rounded.stroke()

        let tipX = min(max(beakX, 22), bounds.width - 22)
        let beak = NSBezierPath()
        let sides = NSBezierPath()
        if beakEdge == .up {
            let base = body.maxY
            beak.move(to: NSPoint(x: tipX - 8, y: base - 1))
            beak.line(to: NSPoint(x: tipX, y: bounds.maxY - 0.5))
            beak.line(to: NSPoint(x: tipX + 8, y: base - 1))
            sides.move(to: NSPoint(x: tipX - 8, y: base))
            sides.line(to: NSPoint(x: tipX, y: bounds.maxY - 0.5))
            sides.line(to: NSPoint(x: tipX + 8, y: base))
        } else {
            let base = body.minY
            beak.move(to: NSPoint(x: tipX - 8, y: base + 1))
            beak.line(to: NSPoint(x: tipX, y: 0.5))
            beak.line(to: NSPoint(x: tipX + 8, y: base + 1))
            sides.move(to: NSPoint(x: tipX - 8, y: base))
            sides.line(to: NSPoint(x: tipX, y: 0.5))
            sides.line(to: NSPoint(x: tipX + 8, y: base))
        }
        beak.close()
        Theme.card.setFill()
        beak.fill()
        Theme.line.setStroke()
        sides.lineWidth = 1
        sides.lineJoinStyle = .round
        sides.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func bodyRect() -> NSRect {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        if beakEdge == .up {
            return NSRect(
                x: inset.minX,
                y: inset.minY,
                width: inset.width,
                height: max(1, inset.height - TourMetrics.beak)
            )
        }
        return NSRect(
            x: inset.minX,
            y: inset.minY + TourMetrics.beak,
            width: inset.width,
            height: max(1, inset.height - TourMetrics.beak)
        )
    }

    private func bubbleContains(_ point: NSPoint) -> Bool {
        if bodyRect().insetBy(dx: -1, dy: -1).contains(point) {
            return true
        }
        let tipX = min(max(beakX, 22), bounds.width - 22)
        let beak = NSBezierPath()
        if beakEdge == .up {
            let base = bodyRect().maxY
            beak.move(to: NSPoint(x: tipX - 8, y: base))
            beak.line(to: NSPoint(x: tipX, y: bounds.maxY))
            beak.line(to: NSPoint(x: tipX + 8, y: base))
        } else {
            let base = bodyRect().minY
            beak.move(to: NSPoint(x: tipX - 8, y: base))
            beak.line(to: NSPoint(x: tipX, y: bounds.minY))
            beak.line(to: NSPoint(x: tipX + 8, y: base))
        }
        beak.close()
        return beak.contains(point)
    }

    @objc private func nextTapped() { onNext?() }
    @objc private func backTapped() { onBack?() }
    @objc private func skipTapped() { onSkip?() }
}

@MainActor
private final class TourDotsView: NSView {
    var count = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var index = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard count > 0 else { return NSSize(width: 0, height: 8) }
        var width: CGFloat = 0
        for dot in 0..<count {
            width += dot == index ? 18 : 6
            if dot + 1 < count {
                width += 5
            }
        }
        return NSSize(width: width, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for dot in 0..<count {
            let width: CGFloat = dot == index ? 18 : 6
            let rect = NSRect(x: x, y: 0, width: width, height: 8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if dot <= index {
                Theme.accent.setFill()
            } else {
                Theme.line.setFill()
            }
            path.fill()
            x += width + 5
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
