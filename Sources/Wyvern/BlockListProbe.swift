// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import WyvernCore
import Foundation
import WebKit

/// Counts likely blocked loads for the toolbar badge.
///
/// WKContentRuleList has no public callback. PerformanceObserver resource entries and
/// element `error` events mix blocks with cache hits, HTTP errors, and offline failures.
/// This script does not use private WebKit SPI. It runs in a named WKContentWorld, reads
/// resource URLs from the DOM, and posts them here. The app counts a URL only when its
/// host is covered by the compiled block set and is not allowlisted.
///
/// Limits: `fetch`, XHR, beacons, CSS `url()`, and WebSockets are invisible. `srcset`
/// candidates may be counted even if the loader never requested them. The main frame
/// itself is not counted. The number is an estimate, and it resets when the main frame
/// navigates. The script only reads attributes; it does not change the page.
enum BlockListProbe {
    static let handlerName = "wyvernBlockProbe"
    static let worldName = "wyvern.blocklist"

    static func installHandler(on controller: WKUserContentController, handler: WKScriptMessageHandler) {
        let world = WKContentWorld.world(name: worldName)
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    static func removeHandler(from controller: WKUserContentController) {
        let world = WKContentWorld.world(name: worldName)
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
    }

    @MainActor
    static func installScript(on controller: WKUserContentController) {
        guard BlockListController.shared.blockingEnabled else { return }
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: WKContentWorld.world(name: worldName)
        )
        controller.addUserScript(script)
    }

    /// Isolated-world probe. Kept in ES5 so a syntax error cannot take the world down.
    static let source = """
    (function () {
      try {
        if (window.__wyvernBlockProbe) { return; }
        window.__wyvernBlockProbe = true;
        var seen = Object.create(null);
        var pending = [];
        var timer = 0;
        function consider(value) {
          if (!value) { return; }
          var href = "";
          try { href = new URL(String(value), document.baseURI).href; } catch (e) { return; }
          if (!href || seen[href]) { return; }
          if (href.indexOf("http://") !== 0 && href.indexOf("https://") !== 0) { return; }
          seen[href] = 1;
          pending.push(href);
          if (pending.length >= 200) { flush(); return; }
          if (!timer) { timer = setTimeout(flush, 50); }
        }
        function flush() {
          if (timer) { clearTimeout(timer); timer = 0; }
          if (!pending.length) { return; }
          var batch = pending;
          pending = [];
          try { webkit.messageHandlers.wyvernBlockProbe.postMessage(batch); } catch (e) {}
        }
        function srcset(value) {
          if (!value) { return; }
          var parts = String(value).split(",");
          for (var i = 0; i < parts.length; i++) {
            var token = parts[i].replace(/^\\s+/, "").split(/\\s+/)[0];
            if (token) { consider(token); }
          }
        }
        function read(node) {
          if (!node || node.nodeType !== 1) { return; }
          var tag = node.tagName;
          if (tag === "IMG" || tag === "SCRIPT" || tag === "IFRAME" || tag === "AUDIO" || tag === "VIDEO" || tag === "SOURCE" || tag === "EMBED" || tag === "TRACK") {
            consider(node.currentSrc || node.src || node.getAttribute("src"));
            srcset(node.srcset || node.getAttribute("srcset"));
          } else if (tag === "LINK") {
            var rel = String(node.rel || node.getAttribute("rel") || "").toLowerCase();
            if (rel.indexOf("stylesheet") >= 0 || rel.indexOf("preload") >= 0 || rel.indexOf("prefetch") >= 0) {
              consider(node.href || node.getAttribute("href"));
            }
          } else if (tag === "OBJECT") {
            consider(node.data || node.getAttribute("data"));
          }
        }
        function scan(node) {
          read(node);
          var kids = node && node.children;
          if (!kids) { return; }
          for (var i = 0; i < kids.length; i++) { scan(kids[i]); }
        }
        function arm() {
          try {
            var root = document.documentElement;
            if (!root) { return; }
            scan(root);
            var observer = new MutationObserver(function (records) {
              try {
                for (var i = 0; i < records.length; i++) {
                  var rec = records[i];
                  if (rec.type === "attributes") { read(rec.target); }
                  else if (rec.addedNodes) {
                    for (var j = 0; j < rec.addedNodes.length; j++) { scan(rec.addedNodes[j]); }
                  }
                }
              } catch (e) {}
            });
            observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ["src", "href", "srcset", "data"] });
          } catch (e) {}
        }
        if (document.documentElement) { arm(); }
        else { document.addEventListener("DOMContentLoaded", arm); }
      } catch (e) {}
    })();
    """
}

@MainActor
final class BlockListProbeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserTab?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        _ = userContentController
        guard message.name == BlockListProbe.handlerName else { return }
        let urls: [String]
        if let batch = message.body as? [String] {
            urls = batch
        } else if let batch = message.body as? [Any] {
            urls = batch.compactMap { $0 as? String }
        } else {
            return
        }
        owner?.absorbProbeURLs(urls)
    }
}
