// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core

@MainActor
final class HealthTraceView: NSView {
    var presentation: HealthPresentation = HealthState.unknown.presentation {
        didSet { needsDisplay = true }
    }
    var reducedMotion = false
    var phase: CGFloat = 0
    var strokeWidth: CGFloat = 1.3
    var showsGrid = false
    var colorOverride: NSColor? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if showsGrid {
            Theme.line.withAlphaComponent(0.35).setStroke()
            let grid = NSBezierPath()
            var x: CGFloat = 0
            while x <= bounds.width {
                grid.move(to: NSPoint(x: x + 0.5, y: 0))
                grid.line(to: NSPoint(x: x + 0.5, y: bounds.height))
                x += 8
            }
            var y: CGFloat = 0
            while y <= bounds.height {
                grid.move(to: NSPoint(x: 0, y: y + 0.5))
                grid.line(to: NSPoint(x: bounds.width, y: y + 0.5))
                y += 8
            }
            grid.lineWidth = 1
            grid.stroke()
        }
        let color = colorOverride ?? Theme.color(hex: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? presentation.darkHex
            : presentation.lightHex)
        color.setStroke()
        let path = beatPath()
        path.lineWidth = strokeWidth
        path.lineJoinStyle = .round
        path.stroke()
        if presentation.headPulseHertz > 0 {
            let alpha = 0.45 + 0.55 * abs(sin(Double(phase) * .pi * presentation.headPulseHertz / 30))
            color.withAlphaComponent(alpha).setFill()
        } else {
            color.setFill()
        }
        let head = NSRect(x: bounds.width - 4, y: bounds.midY - 2, width: 4, height: 4)
        NSBezierPath(ovalIn: head).fill()
    }

    private func beatPath() -> NSBezierPath {
        let path = NSBezierPath()
        let width = bounds.width
        let mid = bounds.midY
        let amp = bounds.height * 0.38
        path.move(to: NSPoint(x: 0, y: mid))
        if presentation.beatsPerMinute <= 0 {
            if presentation.beatShapeID == "flatline" {
                var x: CGFloat = 0
                var on = true
                let offset = reducedMotion ? 0 : phase.truncatingRemainder(dividingBy: 12)
                while x < width {
                    let next = min(x + 6, width)
                    if on {
                        path.line(to: NSPoint(x: next, y: mid))
                    } else {
                        path.move(to: NSPoint(x: next, y: mid))
                    }
                    on.toggle()
                    x = next
                }
                _ = offset
            } else {
                path.line(to: NSPoint(x: width, y: mid))
            }
            return path
        }
        let scale = CGFloat(presentation.beatWidthScale)
        let spacing = max(18, 90 / CGFloat(max(presentation.beatsPerMinute, 1)) * 18) * scale
        var x: CGFloat = reducedMotion ? 4 : (-phase).truncatingRemainder(dividingBy: spacing)
        while x < width + spacing {
            let jitter = presentation.intervalJitterFraction
            let heightJitter = presentation.beatHeightJitterFraction
            let localAmp = amp * CGFloat(1 + heightJitter * 0.2)
            switch presentation.beatShapeID {
            case "wide-stretched":
                path.line(to: NSPoint(x: x, y: mid))
                path.line(to: NSPoint(x: x + 3 * scale, y: mid - localAmp * 0.4))
                path.line(to: NSPoint(x: x + 8 * scale, y: mid + localAmp * 0.15))
                path.line(to: NSPoint(x: x + 14 * scale, y: mid))
            case "jagged-spike":
                path.line(to: NSPoint(x: x, y: mid))
                path.line(to: NSPoint(x: x + 2, y: mid - localAmp))
                path.line(to: NSPoint(x: x + 4, y: mid + localAmp * 0.6))
                path.line(to: NSPoint(x: x + 6, y: mid))
            default:
                path.line(to: NSPoint(x: x, y: mid))
                path.line(to: NSPoint(x: x + 2, y: mid))
                path.line(to: NSPoint(x: x + 3, y: mid - localAmp))
                path.line(to: NSPoint(x: x + 4, y: mid + localAmp * 0.35))
                path.line(to: NSPoint(x: x + 6, y: mid))
            }
            x += spacing * CGFloat(1 + jitter * 0.1)
        }
        return path
    }
}

@MainActor
final class HealthGlyphView: NSView {
    var presentation: HealthPresentation = HealthState.unknown.presentation {
        didSet { needsDisplay = true }
    }
    var colorOverride: NSColor? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = colorOverride ?? Theme.color(hex: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? presentation.darkHex
            : presentation.lightHex)
        color.setStroke()
        color.setFill()
        let inset = bounds.insetBy(dx: 2, dy: 2)
        switch presentation.glyphName {
        case "circle":
            NSBezierPath(ovalIn: inset).fill()
        case "triangle":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset.midX, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            path.close()
            path.fill()
        case "cross":
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.move(to: NSPoint(x: inset.minX, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            path.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            path.stroke()
        case "dash":
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: inset.minX, y: inset.midY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.midY))
            path.stroke()
        default:
            break
        }
    }
}

@MainActor
final class HealthPanelRoot: NSView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityIdentifier() -> String { "app1.netHealth.panel" }

    override func accessibilityChildren() -> [Any]? { subviews }
}

/// Toolbar badge. A borderless `NSButton`: stock tracking sends `action` to `target` on
/// mouse-up inside, and accessibility press and keyboard activation do the same.
@MainActor
final class NetworkHealthBadge: NSButton {
    var snapshot: NetworkHealthSnapshot = NetworkHealthSnapshot(
        host: "",
        scheme: "",
        state: .unknown,
        stats: .empty,
        samples: [],
        presentation: HealthState.unknown.presentation,
        probeKind: nil,
        resolvedIP: nil,
        protocolName: nil,
        enabled: true,
        probing: false,
        hopCount: nil,
        announcePolitely: false,
        accessibilityLabel: HealthState.unknown.accessibilityLabel(host: "", medianRTT: nil)
    ) {
        didSet {
            apply()
            needsDisplay = true
        }
    }
    private let glyph = HealthGlyphView()
    private let trace = HealthTraceView()
    private let label = NSTextField(labelWithString: "IDLE")
    private var timer: Timer?
    private var fadeTimer: Timer?
    private var phase: CGFloat = 0
    private var fadeFrom: (CGFloat, CGFloat, CGFloat)?
    private var fadeTo: (CGFloat, CGFloat, CGFloat)?
    private var fadeStart: Date?
    private var currentRGB: (CGFloat, CGFloat, CGFloat)?
    private var targetHex = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .shadowlessSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        trace.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.mono(size: 9, weight: .semibold)
        label.textColor = Theme.mute
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(trace)
        addSubview(label)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 10),
            glyph.heightAnchor.constraint(equalToConstant: 10),
            trace.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            trace.centerYAnchor.constraint(equalTo: centerYAnchor),
            trace.widthAnchor.constraint(equalToConstant: 28),
            trace.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: trace.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("app1.netHealth.badge")
        setAccessibilityElement(true)
        focusRingType = .exterior
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
        fadeTimer?.invalidate()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 92, height: MonoMetrics.netHealthBadgeHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: MonoMetrics.netHealthBadgeRadius,
            yRadius: MonoMetrics.netHealthBadgeRadius
        )
        Theme.field.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    var extraAccessibilityChild: NSView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// The glyph, trace, and label are drawing only. Every point inside is the button, so the
    /// label text field cannot take the click. `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func accessibilityChildren() -> [Any]? {
        var kids: [Any] = subviews
        if let extraAccessibilityChild {
            kids.append(extraAccessibilityChild)
        }
        return kids
    }

    func setReducedMotion(_ reduced: Bool) {
        trace.reducedMotion = reduced
        if reduced {
            timer?.invalidate()
            timer = nil
            fadeTimer?.invalidate()
            fadeTimer = nil
            if !targetHex.isEmpty {
                snapColor(targetHex)
            }
        } else {
            startTimer()
        }
    }

    func pauseSweep(_ pause: Bool) {
        if pause {
            timer?.invalidate()
            timer = nil
        } else if !trace.reducedMotion {
            startTimer()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        let speed = snapshot.presentation.barSweepPointsPerSecond
        phase += CGFloat(speed / 30.0)
        trace.phase = phase
        trace.needsDisplay = true
    }

    private func apply() {
        glyph.presentation = snapshot.presentation
        trace.presentation = snapshot.presentation
        label.stringValue = snapshot.presentation.label
        let hex = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? snapshot.presentation.darkHex
            : snapshot.presentation.lightHex
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            fadeTimer?.invalidate()
            fadeTimer = nil
            snapColor(hex)
        } else if hex != targetHex {
            startColorFade(to: hex)
        }
        targetHex = hex
        setAccessibilityLabel(snapshot.accessibilityLabel)
        if snapshot.announcePolitely {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: snapshot.accessibilityLabel as NSString
            ])
        }
    }

    private func startColorFade(to hex: String) {
        let dest = rgb(Theme.color(hex: hex))
        guard let from = currentRGB else {
            snapColor(hex)
            return
        }
        fadeFrom = from
        fadeTo = dest
        fadeStart = Date()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickFade()
            }
        }
    }

    private func tickFade() {
        guard let from = fadeFrom, let to = fadeTo, let start = fadeStart else { return }
        let t = min(1, Date().timeIntervalSince(start) / HealthLimits.colorCrossfade)
        let mixed = (
            from.0 + (to.0 - from.0) * CGFloat(t),
            from.1 + (to.1 - from.1) * CGFloat(t),
            from.2 + (to.2 - from.2) * CGFloat(t)
        )
        currentRGB = mixed
        applyColor(NSColor(srgbRed: mixed.0, green: mixed.1, blue: mixed.2, alpha: 1))
        if t >= 1 {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func snapColor(_ hex: String) {
        let color = Theme.color(hex: hex)
        currentRGB = rgb(color)
        applyColor(color)
    }

    private func applyColor(_ color: NSColor) {
        label.textColor = color
        glyph.colorOverride = color
        trace.colorOverride = color
    }

    private func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
    }
}

@MainActor
final class NetworkHealthPanelController: NSViewController {
    let service: NetworkHealthService
    private let trace = HealthTraceView()
    private let rttLabel = NSTextField(labelWithString: "—")
    private let hostValue = NSTextField(labelWithString: "—")
    private let ipValue = NSTextField(labelWithString: "—")
    private let protoValue = NSTextField(labelWithString: "—")
    private let jitterValue = NSTextField(labelWithString: "—")
    private let lossValue = NSTextField(labelWithString: "—")
    private let hopsValue = NSTextField(labelWithString: "—")
    private let probeValue = NSTextField(labelWithString: "—")
    private let hopsList = NSTextField(wrappingLabelWithString: "")
    private let traceButton = DepthButton(title: "Trace", kind: .secondary)
    private let contentStack = NSStackView()
    private let inset: CGFloat = 20
    private let rowSpacing: CGFloat = 12
    private var protocolRow: NSGridRow?
    private var layoutSignature = ""
    private var timer: Timer?
    private var phase: CGFloat = 0

    init(service: NetworkHealthService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = HealthPanelRoot(frame: NSRect(x: 0, y: 0, width: MonoMetrics.netHealthPanelWidth, height: 340))
        root.wantsLayer = true
        view = root

        trace.showsGrid = true
        trace.strokeWidth = 1.8
        trace.translatesAutoresizingMaskIntoConstraints = false
        rttLabel.font = Theme.mono(size: 24, weight: .medium)
        rttLabel.textColor = Theme.text
        rttLabel.alignment = .center

        let captions = ["Host", "IP", "Protocol", "Jitter", "Loss", "Hops", "Probe"]
        let values = [hostValue, ipValue, protoValue, jitterValue, lossValue, hopsValue, probeValue]
        let rows: [[NSView]] = zip(captions, values).map { pair in
            let (caption, value) = pair
            return [makeCaption(caption), configuredValue(value)] as [NSView]
        }
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = 14
        grid.column(at: 0).width = 76
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        protocolRow = grid.row(at: 2)

        probeValue.setAccessibilityIdentifier("app1.netHealth.probeKind")
        probeValue.setAccessibilityElement(true)
        probeValue.setAccessibilityRole(.staticText)

        hopsList.font = Theme.mono(size: 11)
        hopsList.textColor = Theme.text
        hopsList.alignment = .left
        hopsList.preferredMaxLayoutWidth = MonoMetrics.netHealthPanelWidth - inset * 2
        hopsList.isHidden = hopsList.stringValue.isEmpty

        traceButton.target = self
        traceButton.action = #selector(runTrace)
        traceButton.setAccessibilityIdentifier("app1.netHealth.trace")
        traceButton.applySettingsStyle()

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = rowSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(trace)
        contentStack.addArrangedSubview(rttLabel)
        contentStack.addArrangedSubview(grid)
        contentStack.addArrangedSubview(hopsList)
        contentStack.addArrangedSubview(traceButton)
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            trace.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            trace.heightAnchor.constraint(equalToConstant: 64),
            grid.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
        apply(service.currentSnapshot)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resizeToFit()
    }

    deinit {
        timer?.invalidate()
    }

    func apply(_ snapshot: NetworkHealthSnapshot) {
        trace.presentation = snapshot.presentation
        if let ms = snapshot.stats.medianMilliseconds {
            rttLabel.stringValue = "\(ms) ms"
        } else {
            rttLabel.stringValue = "—"
        }
        hostValue.stringValue = snapshot.host.isEmpty ? "—" : snapshot.host
        ipValue.stringValue = snapshot.resolvedIP ?? "—"
        if let proto = snapshot.protocolName, !proto.isEmpty {
            protoValue.stringValue = proto
            protocolRow?.isHidden = false
        } else {
            protoValue.stringValue = ""
            protocolRow?.isHidden = true
        }
        if let jitter = snapshot.stats.jitterMilliseconds {
            jitterValue.stringValue = "\(jitter) ms"
        } else {
            jitterValue.stringValue = "—"
        }
        lossValue.stringValue = String(format: "%.1f%%", snapshot.stats.lossPercent)
        if let hops = snapshot.hopCount {
            hopsValue.stringValue = "\(hops)"
        } else {
            hopsValue.stringValue = "—"
        }
        let kind = snapshot.probeKind?.displayName ?? "—"
        probeValue.stringValue = kind
        probeValue.setAccessibilityLabel(kind)
        probeValue.setAccessibilityValue(kind)
        view.setAccessibilityLabel("Network health \(kind)")
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        trace.reducedMotion = reduced
        if reduced {
            timer?.invalidate()
            timer = nil
        }
        updateLayoutIfNeeded()
    }

    private func tick() {
        let snapshot = service.currentSnapshot
        apply(snapshot)
        phase += CGFloat(snapshot.presentation.panelSweepPointsPerSecond / 30.0)
        trace.phase = phase
        trace.needsDisplay = true
    }

    @objc private func runTrace() {
        hopsList.stringValue = "Tracing…"
        hopsList.isHidden = false
        updateLayoutIfNeeded()
        service.trace { [weak self] result in
            Task { @MainActor in
                self?.showTrace(result)
            }
        }
    }

    private func showTrace(_ result: TracerouteResult) {
        switch result {
        case .hops(let hops):
            hopsList.stringValue = hops.map { hop in
                let rtt = hop.rtt.map { String(format: "%.0f ms", $0 * 1000) } ?? "*"
                return "\(hop.ttl)  \(hop.ip ?? "*")  \(rtt)"
            }.joined(separator: "\n")
        case .unavailable:
            hopsList.stringValue = "Trace unavailable"
        case .cancelled:
            hopsList.stringValue = "Trace cancelled"
        }
        hopsList.isHidden = hopsList.stringValue.isEmpty
        updateLayoutIfNeeded()
    }

    private func makeCaption(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = Theme.font(size: 12, weight: .semibold)
        field.textColor = Theme.mute
        field.alignment = .right
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    private func configuredValue(_ field: NSTextField) -> NSTextField {
        field.font = Theme.font(size: 12)
        field.textColor = Theme.text
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func updateLayoutIfNeeded() {
        let signature = [
            hostValue.stringValue,
            ipValue.stringValue,
            protoValue.stringValue,
            protocolRow?.isHidden == true ? "0" : "1",
            jitterValue.stringValue,
            lossValue.stringValue,
            hopsValue.stringValue,
            probeValue.stringValue,
            hopsList.stringValue,
            hopsList.isHidden ? "h0" : "h1",
            rttLabel.stringValue
        ].joined(separator: "\u{1f}")
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        resizeToFit()
    }

    private func resizeToFit() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let height = ceil(contentStack.fittingSize.height + inset * 2)
        guard height > 40 else { return }
        if abs(view.frame.height - height) < 0.5, abs(preferredContentSize.height - height) < 0.5 {
            return
        }
        let size = NSSize(width: MonoMetrics.netHealthPanelWidth, height: height)
        view.setFrameSize(size)
        preferredContentSize = size
    }
}
