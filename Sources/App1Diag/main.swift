// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import Foundation
import App1Core

@main
enum App1DiagMain {
    static func main() {
        var home = FileManager.default.homeDirectoryForCurrentUser
        var zenRoot: URL?
        var diagnose = false
        var index = 0
        let args = CommandLine.arguments
        while index < args.count {
            let arg = args[index]
            if arg == "--zen-diagnose" {
                diagnose = true
            } else if arg == "--home", index + 1 < args.count {
                index += 1
                home = URL(fileURLWithPath: args[index], isDirectory: true)
            } else if arg == "--zen-root", index + 1 < args.count {
                index += 1
                zenRoot = URL(fileURLWithPath: args[index], isDirectory: true)
            }
            index += 1
        }
        if !diagnose {
            fputs("usage: App1Diag --zen-diagnose [--home DIR] [--zen-root DIR]\n", stderr)
            exit(1)
        }
        let root = zenRoot ?? ZenDetector.supportFolder(home: home, name: "zen")
        print(ZenDetector.diagnose(root: root, home: home))
        print(BrowserDiagnostics.run(home: home))
        fflush(stdout)
    }
}
