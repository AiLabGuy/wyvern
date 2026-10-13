// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import App1Core

@main
enum AppMain {
    static func main() {
        // Process entry is the main thread. Enable bench marks from argv before
        // NSApplication.shared so process-start is the earliest timestamp.
        BenchMarks.enableIfRequested(arguments: CommandLine.arguments)
        BenchMarks.emitOnce("process-start")
        // The delegate must stay strongly referenced; NSApplication.delegate is weak.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
    }
}
