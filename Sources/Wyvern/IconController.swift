// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import WyvernCore
import UniformTypeIdentifiers

/// Loads stored icons and applies the Dock icon. Use it on the main thread.
/// The type is not `@MainActor`: the tab strip reads it from the window controller,
/// which is not isolated.
final class IconController {
    static let shared = IconController()

    let library: IconLibrary
    private var cache: [String: NSImage] = [:]

    init(library: IconLibrary) {
        self.library = library
    }

    convenience init() {
        self.init(library: IconLibrary())
    }

    func applyDockIcon() {
        switch library.appIcon {
        case .style(.default):
            NSApplication.shared.applicationIconImage = nil
        case .style(let style):
            // A missing variant must not leave a previous custom image on the Dock.
            guard let image = Self.bundledStyleImage(style) else {
                NSApplication.shared.applicationIconImage = nil
                return
            }
            NSApplication.shared.applicationIconImage = image
        case .custom:
            guard let url = library.customAppIconURL(),
                  let image = NSImage(contentsOf: url),
                  image.isValid else {
                NSApplication.shared.applicationIconImage = nil
                return
            }
            NSApplication.shared.applicationIconImage = image
        }
    }

    func image(forBookmark id: UUID) -> NSImage? {
        guard let url = library.bookmarkIconURL(id: id) else { return nil }
        return image(at: url)
    }

    func hasBookmarkIcon(id: UUID) -> Bool {
        library.bookmarkIconURL(id: id) != nil
    }

    func image(forHost key: String) -> NSImage? {
        guard let url = library.hostIconURL(key: key) else { return nil }
        return image(at: url)
    }

    func setBuiltIn(_ style: AppIconStyle) -> IconUploadError? {
        cache.removeAll()
        switch library.setBuiltInAppIcon(style) {
        case .failure(let error):
            return error
        case .success:
            applyDockIcon()
            return nil
        }
    }

    func installAppIcon(from url: URL) -> IconUploadError? {
        cache.removeAll()
        switch library.installFileForAppIcon(at: url) {
        case .failure(let error):
            return error
        case .success:
            applyDockIcon()
            return nil
        }
    }

    func resetAppIcon() -> IconUploadError? {
        setBuiltIn(.default)
    }

    func installBookmarkIcon(id: UUID, from url: URL) -> IconUploadError? {
        cache.removeAll()
        switch library.installFile(at: url, forBookmark: id) {
        case .failure(let error):
            return error
        case .success:
            return nil
        }
    }

    func resetBookmarkIcon(id: UUID) {
        cache.removeAll()
        library.resetBookmarkIcon(id: id)
    }

    func installHostIcon(host raw: String, from url: URL) -> Result<String, IconUploadError> {
        cache.removeAll()
        return library.installFile(at: url, forHost: raw)
    }

    func removeHostIcon(_ key: String) {
        cache.removeAll()
        library.resetHostIcon(key)
    }

    static func bundledStyleImage(_ style: AppIconStyle) -> NSImage? {
        switch style {
        case .default:
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: url), image.isValid {
                return image
            }
            return nil
        case .graphite, .hermes, .neon:
            guard let name = variantResourceName(style) else { return nil }
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "IconVariants")
                ?? Bundle.main.url(forResource: name, withExtension: "png")
            guard let url, let image = NSImage(contentsOf: url), image.isValid else { return nil }
            return image
        }
    }

    static func variantResourceName(_ style: AppIconStyle) -> String? {
        switch style {
        case .default:
            return nil
        case .graphite:
            return "wyvern-icon-graphite"
        case .hermes:
            return "wyvern-icon-hermes"
        case .neon:
            return "wyvern-icon-neon"
        }
    }

    static func message(for error: IconUploadError) -> String {
        switch error {
        case .empty:
            return "That file is empty."
        case .tooLarge:
            return "That file is larger than 5 MB."
        case .unsupportedType, .extensionMismatch, .decodeFailed, .absurdDimensions:
            return "Choose a PNG, JPEG, ICNS, or HEIC image under 5 MB."
        case .imageIOUnavailable:
            return "This build cannot read images."
        case .unreadable:
            return "That file could not be read."
        case .writeFailed:
            return "The icon could not be saved."
        case .invalidHost:
            return "Enter a site host, such as example.com."
        }
    }

    private func image(at url: URL) -> NSImage? {
        if let cached = cache[url.path] {
            return cached
        }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cache[url.path] = image
        return image
    }
}

enum IconPickPanel {
    static func choose(from window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a PNG, JPEG, ICNS, or HEIC image."
        var types: [UTType] = [.png, .jpeg, .heic, .heif]
        if let icns = UTType("com.apple.icns") {
            types.append(icns)
        }
        panel.allowedContentTypes = types
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
