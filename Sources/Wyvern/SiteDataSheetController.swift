// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WebKit

/// Lists `WKWebsiteDataStore` records with per-site Remove and Remove All.
@MainActor
final class SiteDataSheetController: NSWindowController {
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "Loading…")
    private let removeAllButton = DepthButton(title: "Remove All", kind: .secondary)
    private var records: [WKWebsiteDataRecord] = []
    private var working = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Site Data"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.page
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        build()
        window.setAccessibilityIdentifier("wyvern.siteData")
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Site data")
        title.font = Theme.font(size: 18, weight: .bold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false

        status.font = Theme.font(size: 12)
        status.textColor = Theme.mute
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setAccessibilityIdentifier("wyvern.siteData.status")

        removeAllButton.controlHeight = 28
        removeAllButton.font = Theme.font(size: 12.5, weight: .semibold)
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll)
        removeAllButton.setAccessibilityIdentifier("wyvern.siteData.removeAll")

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("wyvern.siteData.list")
        document.addSubview(stack)

        content.addSubview(title)
        content.addSubview(status)
        content.addSubview(removeAllButton)
        content.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            status.trailingAnchor.constraint(lessThanOrEqualTo: removeAllButton.leadingAnchor, constant: -12),
            removeAllButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            removeAllButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: document.widthAnchor)
        ])
    }

    private func reload() {
        status.stringValue = "Loading…"
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            let fetched = records
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.show(fetched)
                }
            }
        }
    }

    private func show(_ fetched: [WKWebsiteDataRecord]) {
        records = fetched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if records.isEmpty {
            status.stringValue = "No site data"
            let empty = NSTextField(labelWithString: "No site data is stored.")
            empty.font = Theme.font(size: 13)
            empty.textColor = Theme.mute
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
            empty.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8).isActive = true
            return
        }
        status.stringValue = "\(records.count) \(records.count == 1 ? "site" : "sites")"
        for (index, record) in records.enumerated() {
            stack.addArrangedSubview(row(record, index: index))
        }
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func row(_ record: WKWebsiteDataRecord, index: Int) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: record.displayName)
        name.font = Theme.font(size: 13, weight: .semibold)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remove = DepthButton(title: "Remove", kind: .secondary)
        remove.controlHeight = 28
        remove.font = Theme.font(size: 12.5, weight: .semibold)
        remove.target = self
        remove.action = #selector(removeOne(_:))
        remove.tag = index
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.setAccessibilityLabel("Remove \(record.displayName)")
        host.addSubview(name)
        host.addSubview(remove)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -12),
            remove.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: 44)
        ])
        return host
    }

    @objc private func removeOne(_ sender: NSButton) {
        guard records.indices.contains(sender.tag), !working else { return }
        let record = records[sender.tag]
        remove(records: [record])
    }

    @objc private func removeAll() {
        guard !records.isEmpty, !working else { return }
        remove(records: records)
    }

    private func remove(records removing: [WKWebsiteDataRecord]) {
        working = true
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: removing) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.working = false
                    self?.reload()
                }
            }
        }
    }
}
