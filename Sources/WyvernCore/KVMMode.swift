// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// http(s) origins that use KVM mode. An origin is scheme, host, and port.
/// The host is lowercased. Default ports (80 and 443) are omitted. Paths and queries are not part of the origin.
public struct KVMSiteList: Equatable, Sendable, Codable {
    /// Stable lexicographic order. Duplicates and values that are not http(s) origins are dropped.
    public private(set) var origins: [String]

    public init(origins: [String] = []) {
        self.origins = Self.canonical(origins)
    }

    /// `nil` when the URL is not http or https, or the host is missing.
    public static func normalizedOrigin(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let rawHost = url.host?.lowercased(), rawHost.isEmpty == false else {
            return nil
        }
        let host = rawHost.contains(":") && rawHost.hasPrefix("[") == false ? "[\(rawHost)]" : rawHost
        if let port = url.port, Self.isDefaultPort(port, scheme: scheme) == false {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public func contains(_ url: URL) -> Bool {
        guard let origin = Self.normalizedOrigin(from: url) else { return false }
        return origins.contains(origin)
    }

    /// Unchanged when the URL has no http(s) origin.
    public func adding(_ url: URL) -> KVMSiteList {
        guard let origin = Self.normalizedOrigin(from: url) else { return self }
        guard origins.contains(origin) == false else { return self }
        return KVMSiteList(origins: origins + [origin])
    }

    /// Unchanged when the URL is not in the list.
    public func removing(_ url: URL) -> KVMSiteList {
        guard let origin = Self.normalizedOrigin(from: url) else { return self }
        return KVMSiteList(origins: origins.filter { $0 != origin })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String].self)
        origins = Self.canonical(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(origins)
    }

    private static func canonical(_ raw: [String]) -> [String] {
        var unique = Set<String>()
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, let url = URL(string: trimmed),
                  let origin = normalizedOrigin(from: url) else {
                continue
            }
            unique.insert(origin)
        }
        return unique.sorted()
    }

    private static func isDefaultPort(_ port: Int, scheme: String) -> Bool {
        (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
    }
}

/// Modifier keys for `KVMKeyRouting`. Shift does not by itself send a key to the page.
public struct KVMKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KVMKeyModifiers(rawValue: 1 << 0)
    public static let option = KVMKeyModifiers(rawValue: 1 << 1)
    public static let control = KVMKeyModifiers(rawValue: 1 << 2)
    public static let shift = KVMKeyModifiers(rawValue: 1 << 3)

    public var hasCommandControlOrOption: Bool {
        contains(.command) || contains(.control) || contains(.option)
    }
}

public enum KVMKeyDecision: Equatable, Sendable {
    case passToApp
    case sendToPage
    case toggleCapture
}

/// Where a key goes while a KVM-mode page is focused.
/// Control-Option-Command-K (key code 40) toggles capture whenever KVM mode is active, including while capture is suspended.
public enum KVMKeyRouting {
    /// kVK_ANSI_K. The Carbon header is not imported.
    public static let escapeKeyCode: UInt16 = 40

    public static func route(
        keyCode: UInt16,
        modifiers: KVMKeyModifiers,
        kvmActive: Bool,
        captureSuspended: Bool
    ) -> KVMKeyDecision {
        guard kvmActive else { return .passToApp }
        if keyCode == escapeKeyCode,
           modifiers.contains(.control),
           modifiers.contains(.option),
           modifiers.contains(.command) {
            return .toggleCapture
        }
        if captureSuspended { return .passToApp }
        if modifiers.hasCommandControlOrOption { return .sendToPage }
        return .passToApp
    }
}

/// Main-frame page script. Callers run it only for a KVM origin, so other sites never see it.
public enum KVMMediaScript {
    public static let source = """
    (function(){
      if (window.__wyvernKVMMedia) { return; }
      var root = document.documentElement;
      if (!root) { return; }
      window.__wyvernKVMMedia = true;
      function patch(video) {
        try { video.disablePictureInPicture = true; } catch (e) {}
        try { video.disableRemotePlayback = true; } catch (e) {}
      }
      function scan(node) {
        if (!node || !node.querySelectorAll) { return; }
        var nodes = node.querySelectorAll("video");
        for (var i = 0; i < nodes.length; i++) { patch(nodes[i]); }
      }
      scan(root);
      if (window.MutationObserver && root) {
        try {
          var observer = new MutationObserver(function(records) {
            for (var i = 0; i < records.length; i++) {
              var added = records[i].addedNodes;
              for (var j = 0; j < added.length; j++) {
                var node = added[j];
                if (!node || node.nodeType !== 1) { continue; }
                if (node.tagName === "VIDEO") { patch(node); }
                scan(node);
              }
            }
          });
          observer.observe(root, { childList: true, subtree: true });
          window.__wyvernKVMObserver = observer;
        } catch (e) {}
      }
      try {
        var session = navigator.mediaSession;
        if (session && session.setActionHandler) {
          var actions = ["play","pause","seekbackward","seekforward","previoustrack","nexttrack","skipad","stop","seekto"];
          for (var k = 0; k < actions.length; k++) {
            try { session.setActionHandler(actions[k], null); } catch (e2) {}
          }
        }
      } catch (e) {}
    })();
    """

    /// Removes the observer installed by `source` on the same document.
    public static let undo = """
    (function(){
      window.__wyvernKVMMedia = false;
      if (window.__wyvernKVMObserver) {
        try { window.__wyvernKVMObserver.disconnect(); } catch (e) {}
        window.__wyvernKVMObserver = null;
      }
      if (!document.querySelectorAll) { return; }
      var nodes = document.querySelectorAll("video");
      for (var i = 0; i < nodes.length; i++) {
        try { nodes[i].disablePictureInPicture = false; } catch (e) {}
        try { nodes[i].disableRemotePlayback = false; } catch (e) {}
      }
    })();
    """
}
