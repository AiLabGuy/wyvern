// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import WyvernCore

private let grantSentence = "Grant it on the build Mac: System Settings > Privacy & Security > Accessibility > + > add the act_runner binary (the process that launches this job; its path is printed below), enable it, then re-run the job. If the runner is started from Terminal, add Terminal instead."

private let keyT: CGKeyCode = 17
private let keyW: CGKeyCode = 13
private let keyA: CGKeyCode = 0
private let keyReturn: CGKeyCode = 36
private let keyTab: CGKeyCode = 48

@main
enum WyvernBenchMain {
    static func main() {
        if CommandLine.arguments.contains("--zen-diagnose") {
            var home = FileManager.default.homeDirectoryForCurrentUser
            if let idx = CommandLine.arguments.firstIndex(of: "--home"),
               idx + 1 < CommandLine.arguments.count {
                home = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
            }
            let root = ZenDetector.supportFolder(home: home, name: "zen")
            print(ZenDetector.diagnose(root: root, home: home))
            print(BrowserDiagnostics.run(home: home))
            fflush(stdout)
            exit(0)
        }
        let code = BenchSession().run()
        fflush(stdout)
        exit(code)
    }
}

private struct MetricSpec {
    var name: String
    var unit: String
    var description: String
}

private final class MetricBucket {
    let spec: MetricSpec
    var values: [Double] = []
    var errors: Int = 0
    var lastChildren: Int?

    init(_ spec: MetricSpec) {
        self.spec = spec
    }

    func add(_ value: Double, children: Int? = nil) {
        values.append(value)
        if let children {
            lastChildren = children
            print("BENCH_SAMPLE \(spec.name) value=\(formatNumber(value, unit: spec.unit)) children=\(children)")
        } else {
            print("BENCH_SAMPLE \(spec.name) value=\(formatNumber(value, unit: spec.unit))")
        }
        fflush(stdout)
    }

    func miss(_ reason: String, children: Int? = nil) {
        errors += 1
        if let children {
            lastChildren = children
        }
        print("BENCH_SAMPLE \(spec.name) error=\(reason)")
        fflush(stdout)
    }

    func summary() -> BenchSummary {
        BenchStats.summarize(values: values, errors: errors)
    }
}

private struct CLI {
    var appPath = ""
    var url = ""
    var runs = 9
    var output = "build/bench-results.json"
    var table = "build/bench-results.md"
}

private final class BenchSession {
    private var metrics: [String: MetricBucket] = [:]
    private var notes: [String] = []
    private var loadStart = ""
    private var loadEnd = ""

    func run() -> Int32 {
        let blocked = sessionBlockCode()
        if blocked != 0 {
            return blocked
        }
        guard let cli = parseCLI() else {
            print("usage: WyvernBench --app PATH --url URL [--runs 9] [--output PATH] [--table PATH]")
            fflush(stdout)
            return 1
        }
        guard let binary = BenchPaths.executable(inApp: cli.appPath),
              FileManager.default.isExecutableFile(atPath: binary) else {
            print("BENCH_BLOCKED: application binary is missing at \(cli.appPath)")
            fflush(stdout)
            return 1
        }
        loadStart = HostInfo.loadAverage()
        print("BENCH_BEGIN product=\(AppInfo.displayName) n=\(cli.runs) warmup=1 url=\(cli.url)")
        print("BENCH_ENV macos=\(HostInfo.sysctl("kern.osproductversion")) cpu=\(cpuModel()) arch=\(machine()) loadavg_start=\(loadStart)")
        print("BENCH_NOTE kind=fresh-process-launch purge is not available without sudo; these are not disk-cold starts")
        fflush(stdout)
        notes.append("Fresh-process launch: each cold/warm launch starts a new process. purge(8) is not available without sudo, so this is not a disk-cold start.")
        notes.append("Network and rendering after navigation-started are WebKit's. first-paint is didFinish plus a double requestAnimationFrame message in bench mode only.")
        notes.append("Memory is ri_phys_footprint via proc_pid_rusage(RUSAGE_INFO_V4) for the app pid plus WebKit helpers. Helpers are ppid/responsible-pid children, plus new same-uid pids whose proc_name or proc_pidpath contains com.apple.WebKit (WebContent, Networking, GPU; launchd-parented XPC). 1 MB = 1048576 bytes. Samples are taken 3 s after loads settle. Ten open tabs with childCount 0 is an error, not a number.")

        registerMetrics()

        runFreshLaunches(binary: binary, url: cli.url, runs: cli.runs, warm: false)
        runFreshLaunches(binary: binary, url: cli.url, runs: cli.runs, warm: true)
        runInSession(binary: binary, url: cli.url, runs: cli.runs)

        loadEnd = HostInfo.loadAverage()
        print("BENCH_ENV loadavg_end=\(loadEnd)")
        fflush(stdout)
        return writeReport(cli: cli)
    }

    private func registerMetrics() {
        func add(_ name: String, _ unit: String, _ description: String) {
            metrics[name] = MetricBucket(MetricSpec(name: name, unit: unit, description: description))
        }
        add("M1_window_fresh", "ms", "Fresh-process launch: process-start mark to window-visible mark")
        add("M1_wall_fresh", "ms", "Fresh-process launch: Process.run CLOCK_UPTIME_RAW to window-visible mark")
        add("M1_window_warm", "ms", "Warm fresh-process launch (1 discarded): process-start to window-visible")
        add("M1_wall_warm", "ms", "Warm fresh-process launch (1 discarded): Process.run to window-visible")
        add("M2_paint_fresh", "ms", "Fresh-process launch: process-start to first-paint (didFinish + double-rAF)")
        add("M2_paint_warm", "ms", "Warm fresh-process launch (1 discarded): process-start to first-paint")
        add("M3_new_tab", "ms", "Cmd-T CGEvent to tab-ready mark")
        add("M4_tab_switch", "ms", "Ctrl-Tab CGEvent to tab-switch-completed mark, 5 loaded tabs")
        add("M5_url_enter", "ms", "return-keydown mark to navigation-started mark")
        add("M6_1tab_app", "MB", "phys_footprint of the app pid, 1 loaded tab, 3 s after settle")
        add("M6_1tab_webcontent", "MB", "WebKit WebContent helpers, 1 loaded tab")
        add("M6_1tab_networking", "MB", "WebKit Networking helpers, 1 loaded tab")
        add("M6_1tab_gpu", "MB", "WebKit GPU helpers, 1 loaded tab")
        add("M6_1tab_total", "MB", "App plus WebKit children, 1 loaded tab, 3 s after settle")
        add("M6_10tab_app", "MB", "phys_footprint of the app pid, 10 loaded tabs, 3 s after settle")
        add("M6_10tab_webcontent", "MB", "WebKit WebContent helpers, 10 loaded tabs")
        add("M6_10tab_networking", "MB", "WebKit Networking helpers, 10 loaded tabs")
        add("M6_10tab_gpu", "MB", "WebKit GPU helpers, 10 loaded tabs")
        add("M6_10tab_total", "MB", "App plus WebKit children, 10 loaded tabs, 3 s after settle")
        add("M7_load_fresh", "ms", "navigation-started to navigation-finished for the local bench page")
        add("M7_load_warm", "ms", "Warm fresh-process: navigation-started to navigation-finished")
    }

    private func runFreshLaunches(binary: String, url: String, runs: Int, warm: Bool) {
        let label = warm ? "warm" : "fresh"
        let discard = warm ? 1 : 0
        if warm {
            print("BENCH_PHASE warm-up launch (discarded)")
            fflush(stdout)
            if let launch = try? AppLaunch.start(binary: binary, url: url) {
                _ = launch.collector.wait(name: "first-paint", after: launch.runNanoseconds, timeout: 25)
                launch.stop()
                pause(0.4)
            }
        }
        for index in 1...runs {
            print("BENCH_PHASE \(label) launch \(index)/\(runs)")
            fflush(stdout)
            do {
                let launch = try AppLaunch.start(binary: binary, url: url)
                recordLaunchMetrics(launch, warm: warm)
                launch.stop()
            } catch {
                metrics[warm ? "M1_window_warm" : "M1_window_fresh"]?.miss("launch-failed")
                metrics[warm ? "M1_wall_warm" : "M1_wall_fresh"]?.miss("launch-failed")
                metrics[warm ? "M2_paint_warm" : "M2_paint_fresh"]?.miss("launch-failed")
                metrics[warm ? "M7_load_warm" : "M7_load_fresh"]?.miss("launch-failed")
            }
            _ = discard
            pause(0.3)
        }
    }

    private func recordLaunchMetrics(_ launch: AppLaunch, warm: Bool) {
        let start = launch.runNanoseconds
        let windowName = warm ? "M1_window_warm" : "M1_window_fresh"
        let wallName = warm ? "M1_wall_warm" : "M1_wall_fresh"
        let paintName = warm ? "M2_paint_warm" : "M2_paint_fresh"
        let loadName = warm ? "M7_load_warm" : "M7_load_fresh"

        guard let processStart = launch.collector.wait(name: "process-start", after: 0, timeout: 8) else {
            metrics[windowName]?.miss("missing-process-start")
            metrics[wallName]?.miss("missing-process-start")
            metrics[paintName]?.miss("missing-process-start")
            metrics[loadName]?.miss("missing-process-start")
            printMissingMarks(launch, metric: windowName, expected: "process-start")
            return
        }
        if let visible = launch.collector.wait(name: "window-visible", after: processStart, timeout: 20) {
            metrics[windowName]?.add(BenchClock.milliseconds(processStart, visible))
            metrics[wallName]?.add(BenchClock.milliseconds(start, visible))
        } else {
            metrics[windowName]?.miss("timeout-window-visible")
            metrics[wallName]?.miss("timeout-window-visible")
            printMissingMarks(launch, metric: windowName, expected: "window-visible")
        }
        if let paint = launch.collector.wait(name: "first-paint", after: processStart, timeout: 25) {
            metrics[paintName]?.add(BenchClock.milliseconds(processStart, paint))
        } else {
            let seen = seenText(markNames(launch))
            metrics[paintName]?.miss("missing-first-paint;seen=\(seen)")
            printMissingMarks(launch, metric: paintName, expected: "first-paint")
        }
        if let navStart = launch.collector.first(name: "navigation-started", after: processStart),
           let navEnd = launch.collector.wait(name: "navigation-finished", after: navStart, timeout: 20) {
            metrics[loadName]?.add(BenchClock.milliseconds(navStart, navEnd))
        } else {
            let seen = markNames(launch)
            let missing = seen.contains("navigation-started") ? "navigation-finished" : "navigation-started"
            metrics[loadName]?.miss("timeout-navigation")
            print("BENCH_RUN \(loadName) missing=\(missing) seen=\(seenText(seen))")
            fflush(stdout)
        }
    }

    private func runInSession(binary: String, url: String, runs: Int) {
        print("BENCH_PHASE in-session M3-M6")
        fflush(stdout)
        let baseline = MemorySampler.snapshotPids()
        let launch: AppLaunch
        do {
            launch = try AppLaunch.start(binary: binary, url: url)
        } catch {
            failSession("launch-failed", runs: runs)
            return
        }
        defer { launch.stop() }
        let ready = launch.collector.wait(name: "first-paint", after: launch.runNanoseconds, timeout: 30)
            ?? launch.collector.wait(name: "window-visible", after: launch.runNanoseconds, timeout: 5)
        guard ready != nil, launch.process.isRunning else {
            failSession("window-not-ready", runs: runs)
            return
        }
        launch.activate()
        let ax = AXClient(pid: launch.pid)
        let appeared = waitUntil(15) { ax.exists(identifier: "wyvern.address") && !ax.windowTitle().isEmpty }
        guard appeared else {
            failSession("ax-window-missing", runs: runs)
            return
        }
        pause(0.4)

        runNewTabMetric(launch: launch, ax: ax, runs: runs)
        runTabSwitchMetric(launch: launch, ax: ax, url: url, runs: runs)
        runURLEnterMetric(launch: launch, ax: ax, url: url, runs: runs)
        runMemoryMetric(launch: launch, ax: ax, url: url, runs: runs, baseline: baseline)
    }

    private func failSession(_ reason: String, runs: Int) {
        let names = [
            "M3_new_tab", "M4_tab_switch", "M5_url_enter",
            "M6_1tab_app", "M6_1tab_webcontent", "M6_1tab_networking", "M6_1tab_gpu", "M6_1tab_total",
            "M6_10tab_app", "M6_10tab_webcontent", "M6_10tab_networking", "M6_10tab_gpu", "M6_10tab_total"
        ]
        for name in names {
            for _ in 1...runs {
                if name.hasPrefix("M6_") {
                    metrics[name]?.miss(reason, children: 0)
                } else {
                    metrics[name]?.miss(reason)
                }
            }
        }
    }

    private func runNewTabMetric(launch: AppLaunch, ax: AXClient, runs: Int) {
        print("BENCH_PHASE M3 new tab")
        fflush(stdout)
        launch.activate()
        // Discarded warm-up.
        _ = performNewTab(launch: launch, ax: ax)
        for _ in 1...runs {
            launch.activate()
            if let ms = performNewTab(launch: launch, ax: ax) {
                metrics["M3_new_tab"]?.add(ms)
            } else {
                metrics["M3_new_tab"]?.miss("timeout-tab-ready")
            }
        }
    }

    private func performNewTab(launch: AppLaunch, ax: AXClient) -> Double? {
        let before = BenchMarks.nowNanoseconds()
        guard ax.postCommandKey(virtualKey: keyT) else { return nil }
        guard let ready = launch.collector.wait(name: "tab-ready", after: before, timeout: 8) else {
            return nil
        }
        let ms = BenchClock.milliseconds(before, ready)
        pause(0.15)
        _ = ax.postCommandKey(virtualKey: keyW)
        pause(0.2)
        return ms
    }

    private func runTabSwitchMetric(launch: AppLaunch, ax: AXClient, url: String, runs: Int) {
        print("BENCH_PHASE M4 tab switch")
        fflush(stdout)
        launch.activate()
        let needed = 5
        var opened = max(ax.countTabs(), 1)
        var steps = 0
        while opened < needed, steps < 12 {
            steps += 1
            let before = BenchMarks.nowNanoseconds()
            guard ax.postCommandKey(virtualKey: keyT) else { break }
            _ = launch.collector.wait(name: "tab-ready", after: before, timeout: 6)
            pause(0.15)
            let tabURL = urlWithQuery(url, "tab=\(opened + 1)")
            if !loadURL(ax: ax, launch: launch, url: tabURL, newTab: true) {
                break
            }
            opened = max(ax.countTabs(), opened + 1)
        }
        if ax.countTabs() < 5 {
            for _ in 1...runs {
                metrics["M4_tab_switch"]?.miss("could-not-open-five-tabs")
            }
            return
        }
        pause(0.4)
        launch.activate()
        _ = performSwitch(launch: launch, ax: ax)
        for _ in 1...runs {
            launch.activate()
            if let ms = performSwitch(launch: launch, ax: ax) {
                metrics["M4_tab_switch"]?.add(ms)
            } else {
                metrics["M4_tab_switch"]?.miss("timeout-tab-switch")
            }
        }
    }

    private func performSwitch(launch: AppLaunch, ax: AXClient) -> Double? {
        let before = BenchMarks.nowNanoseconds()
        guard ax.postControlKey(virtualKey: keyTab) else { return nil }
        guard let done = launch.collector.wait(name: "tab-switch-completed", after: before, timeout: 5) else {
            return nil
        }
        pause(0.05)
        return BenchClock.milliseconds(before, done)
    }

    private func runURLEnterMetric(launch: AppLaunch, ax: AXClient, url: String, runs: Int) {
        print("BENCH_PHASE M5 url enter")
        fflush(stdout)
        launch.activate()
        _ = performURLEnter(launch: launch, ax: ax, url: urlWithQuery(url, "enter=warmup"))
        for index in 1...runs {
            launch.activate()
            let target = urlWithQuery(url, "enter=\(index)-\(UInt64.random(in: 1...9_000))")
            switch performURLEnter(launch: launch, ax: ax, url: target) {
            case .success(let ms):
                metrics["M5_url_enter"]?.add(ms)
            case .failure(let reason):
                metrics["M5_url_enter"]?.miss(reason)
            }
        }
    }

    private func performURLEnter(launch: AppLaunch, ax: AXClient, url: String) -> Result<Double, String> {
        guard ax.focusField(identifier: "wyvern.address") else {
            printMissingMarks(launch, metric: "M5_url_enter", expected: "address-focus")
            return .failure("missing-address-focus")
        }
        pause(0.2)
        guard ax.postCommandKey(virtualKey: keyA) else {
            return .failure("post-command-a-failed")
        }
        pause(0.05)
        guard ax.typeUnicode(url) else {
            return .failure("type-failed")
        }
        pause(0.05)
        let before = BenchMarks.nowNanoseconds()
        guard ax.postKey(virtualKey: keyReturn, flags: []) else {
            return .failure("post-return-failed")
        }
        guard let keyNs = launch.collector.wait(name: "return-keydown", after: before, timeout: 3) else {
            printMissingMarks(launch, metric: "M5_url_enter", expected: "return-keydown")
            return .failure("missing-return-keydown;seen=\(seenText(markNames(launch)))")
        }
        guard let nav = launch.collector.wait(name: "navigation-started", after: keyNs, timeout: 8) else {
            printMissingMarks(launch, metric: "M5_url_enter", expected: "navigation-started")
            return .failure("missing-navigation-started;seen=\(seenText(markNames(launch)))")
        }
        _ = launch.collector.wait(name: "navigation-finished", after: nav, timeout: 10)
        pause(0.15)
        return .success(BenchClock.milliseconds(keyNs, nav))
    }

    private func runMemoryMetric(launch: AppLaunch, ax: AXClient, url: String, runs: Int, baseline: Set<pid_t>) {
        print("BENCH_PHASE M6 memory")
        fflush(stdout)
        collapseToOneTab(ax: ax)
        launch.activate()
        _ = loadURL(ax: ax, launch: launch, url: urlWithQuery(url, "mem=1"), newTab: false)
        pause(3.0)
        for _ in 1...runs {
            recordMemory("M6_1tab", appPid: launch.pid, baseline: baseline, requireChildren: false)
            pause(0.25)
        }

        var tabs = max(ax.countTabs(), 1)
        var guardCount = 0
        while tabs < 10, guardCount < 16 {
            guardCount += 1
            let before = BenchMarks.nowNanoseconds()
            guard ax.postCommandKey(virtualKey: keyT) else { break }
            _ = launch.collector.wait(name: "tab-ready", after: before, timeout: 6)
            pause(0.12)
            _ = loadURL(ax: ax, launch: launch, url: urlWithQuery(url, "mem=\(tabs + 1)"), newTab: true)
            tabs = max(ax.countTabs(), tabs + 1)
        }
        if ax.countTabs() < 10 {
            for _ in 1...runs {
                missMemory("M6_10tab", reason: "could-not-open-ten-tabs", children: 0)
            }
            return
        }
        pause(3.0)
        for _ in 1...runs {
            recordMemory("M6_10tab", appPid: launch.pid, baseline: baseline, requireChildren: true)
            pause(0.25)
        }
    }

    private func recordMemory(_ prefix: String, appPid: pid_t, baseline: Set<pid_t>, requireChildren: Bool) {
        guard let sample = MemorySampler.sample(appPid: appPid, baseline: baseline) else {
            missMemory(prefix, reason: "rusage-failed")
            return
        }
        if requireChildren && sample.childCount == 0 {
            missMemory(prefix, reason: "no-webkit-children", children: 0)
            return
        }
        let n = sample.childCount
        metrics["\(prefix)_app"]?.add(MemorySampler.megabytes(sample.appBytes), children: n)
        metrics["\(prefix)_webcontent"]?.add(MemorySampler.megabytes(sample.webContentBytes), children: n)
        metrics["\(prefix)_networking"]?.add(MemorySampler.megabytes(sample.networkingBytes), children: n)
        metrics["\(prefix)_gpu"]?.add(MemorySampler.megabytes(sample.gpuBytes), children: n)
        metrics["\(prefix)_total"]?.add(MemorySampler.megabytes(sample.totalBytes), children: n)
    }

    private func missMemory(_ prefix: String, reason: String, children: Int? = nil) {
        for suffix in ["_app", "_webcontent", "_networking", "_gpu", "_total"] {
            metrics[prefix + suffix]?.miss(reason, children: children)
        }
    }

    private func collapseToOneTab(ax: AXClient) {
        var steps = 0
        while ax.countTabs() > 1, steps < 20 {
            _ = ax.postCommandKey(virtualKey: keyW)
            pause(0.15)
            steps += 1
        }
    }

    @discardableResult
    private func loadURL(ax: AXClient, launch: AppLaunch, url: String, newTab: Bool) -> Bool {
        let field = newTab && ax.exists(identifier: "wyvern.newtab.search") ? "wyvern.newtab.search" : "wyvern.address"
        if ax.exists(identifier: field) {
            _ = ax.focusField(identifier: field)
            pause(0.12)
        }
        _ = ax.postCommandKey(virtualKey: keyA)
        pause(0.04)
        guard ax.typeUnicode(url) else { return false }
        pause(0.04)
        let before = BenchMarks.nowNanoseconds()
        guard ax.postKey(virtualKey: keyReturn, flags: []) else { return false }
        return launch.collector.wait(name: "navigation-finished", after: before, timeout: 12) != nil
    }

    private func urlWithQuery(_ url: String, _ query: String) -> String {
        if url.contains("?") {
            return url + "&" + query
        }
        return url + "?" + query
    }

    private func writeReport(cli: CLI) -> Int32 {
        let order = [
            "M1_window_fresh", "M1_wall_fresh", "M1_window_warm", "M1_wall_warm",
            "M2_paint_fresh", "M2_paint_warm",
            "M3_new_tab", "M4_tab_switch", "M5_url_enter",
            "M6_1tab_app", "M6_1tab_webcontent", "M6_1tab_networking", "M6_1tab_gpu", "M6_1tab_total",
            "M6_10tab_app", "M6_10tab_webcontent", "M6_10tab_networking", "M6_10tab_gpu", "M6_10tab_total",
            "M7_load_fresh", "M7_load_warm"
        ]
        var metricJSON: [[String: Any]] = []
        var table = "| Metric | n | errors | median | p90 | min | max | unit |\n|---|---:|---:|---:|---:|---:|---:|---|\n"
        for name in order {
            guard let bucket = metrics[name] else { continue }
            let summary = bucket.summary()
            let medianText = formatOptional(summary.median, unit: bucket.spec.unit)
            let p90Text = formatOptional(summary.p90, unit: bucket.spec.unit)
            var line = "BENCH_RESULT \(name) median=\(formatResult(summary.median, unit: bucket.spec.unit)) p90=\(formatResult(summary.p90, unit: bucket.spec.unit)) n=\(summary.n) errors=\(summary.errors)"
            if name.hasPrefix("M6_"), let children = bucket.lastChildren {
                line += " children=\(children)"
            }
            print(line)
            table += "| \(name) | \(summary.n) | \(summary.errors) | \(medianText) | \(p90Text) | \(formatOptional(summary.min, unit: bucket.spec.unit)) | \(formatOptional(summary.max, unit: bucket.spec.unit)) | \(bucket.spec.unit) |\n"
            var row: [String: Any] = [
                "name": name,
                "unit": bucket.spec.unit,
                "description": bucket.spec.description,
                "n": summary.n,
                "errors": summary.errors,
                "values": bucket.values
            ]
            if let median = summary.median { row["median"] = median }
            if let p90 = summary.p90 { row["p90"] = p90 }
            if let min = summary.min { row["min"] = min }
            if let max = summary.max { row["max"] = max }
            if let children = bucket.lastChildren { row["children"] = children }
            metricJSON.append(row)
        }
        fflush(stdout)

        let report: [String: Any] = [
            "schema": "wyvern-bench-1",
            "product": AppInfo.displayName,
            "runsRequested": cli.runs,
            "warmupDiscarded": 1,
            "kind": "fresh-process-launch",
            "notes": notes,
            "environment": [
                "macos": HostInfo.sysctl("kern.osproductversion"),
                "cpu": cpuModel(),
                "arch": machine(),
                "loadAverageStart": loadStart,
                "loadAverageEnd": loadEnd
            ],
            "metrics": metricJSON
        ]
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            print("BENCH_BLOCKED: could not encode bench-results.json")
            fflush(stdout)
            return 1
        }
        let markdown = """
        # \(AppInfo.displayName) benchmark

        Fresh-process launch (not disk-cold). N=\(cli.runs), 1 discarded warm-up for warm and in-session metrics.

        macOS \(HostInfo.sysctl("kern.osproductversion")); CPU \(cpuModel()); loadavg start \(loadStart); loadavg end \(loadEnd)

        \(table)
        """
        do {
            try FileManager.default.createDirectory(
                atPath: (cli.output as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: cli.output))
            let tableDir = (cli.table as NSString).deletingLastPathComponent
            if !tableDir.isEmpty && tableDir != "." {
                try FileManager.default.createDirectory(atPath: tableDir, withIntermediateDirectories: true)
            }
            try markdown.write(toFile: cli.table, atomically: true, encoding: .utf8)
        } catch {
            print("BENCH_BLOCKED: could not write results files")
            fflush(stdout)
            return 1
        }
        print("BENCH_WRITTEN json=\(cli.output) table=\(cli.table)")
        print(table)
        fflush(stdout)
        return 0
    }

    private func parseCLI() -> CLI? {
        var cli = CLI()
        let arguments = CommandLine.arguments
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func take() -> String? {
                let next = index + 1
                guard next < arguments.count else { return nil }
                index = next
                return arguments[next]
            }
            switch argument {
            case "--app":
                cli.appPath = take() ?? ""
            case "--url":
                cli.url = take() ?? ""
            case "--runs":
                if let raw = take(), let value = Int(raw), value > 0 {
                    cli.runs = value
                }
            case "--output":
                cli.output = take() ?? cli.output
            case "--table":
                cli.table = take() ?? cli.table
            default:
                break
            }
            index += 1
        }
        if cli.appPath.isEmpty || cli.url.isEmpty {
            return nil
        }
        return cli
    }

    private func sessionBlockCode() -> Int32 {
        let name = HostInfo.command(launchctlPath(), ["managername"])
        if name != "Aqua" {
            print("BENCH_BLOCKED: no GUI session (runner must run as a LaunchAgent in the logged-in user session)")
            fflush(stdout)
            return 2
        }
        let session = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
        let locked = sessionFlag(session, "CGSSessionScreenIsLocked")
        let onConsole = sessionFlag(session, kCGSessionOnConsoleKey as String)
        print("BENCH_SESSION locked=\(locked) onConsole=\(onConsole) sessionKeys=\(session.isEmpty ? 0 : session.count)")
        if locked || !onConsole {
            print("BENCH_BLOCKED_SCREEN_LOCKED: the build Mac's login session is locked, asleep or not on the console (locked=\(locked) onConsole=\(onConsole)).")
            print("BENCH_BLOCKED: benchmarks need the Mac awake and unlocked. They were NOT run.")
            fflush(stdout)
            return 4
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = NSDictionary(dictionary: [key: true])
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
            print("BENCH_BLOCKED: Accessibility permission missing.")
            print(grantSentence)
            print(actRunnerPath())
            fflush(stdout)
            return 2
        }
        return 0
    }

    private func waitUntil(_ seconds: Double, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if body() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return body()
    }

    private func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func markNames(_ launch: AppLaunch) -> [String] {
        Array(Set(launch.collector.snapshot().map(\.name))).sorted()
    }

    private func seenText(_ names: [String]) -> String {
        names.isEmpty ? "(none)" : names.joined(separator: ",")
    }

    private func printMissingMarks(_ launch: AppLaunch, metric: String, expected: String) {
        print("BENCH_RUN \(metric) missing=\(expected) seen=\(seenText(markNames(launch)))")
        fflush(stdout)
    }

    private func sessionFlag(_ session: [String: Any], _ key: String) -> Bool {
        if let value = session[key] as? Bool { return value }
        if let number = session[key] as? NSNumber { return number.boolValue }
        if let number = session[key] as? Int { return number != 0 }
        return false
    }
}

private func formatNumber(_ value: Double, unit: String) -> String {
    if unit == "MB" {
        return String(format: "%.2f", value)
    }
    return String(format: "%.1f", value)
}

private func formatOptional(_ value: Double?, unit: String) -> String {
    guard let value else { return "—" }
    return formatNumber(value, unit: unit)
}

private func formatResult(_ value: Double?, unit: String) -> String {
    guard let value else { return "na" }
    return formatNumber(value, unit: unit)
}

private func cpuModel() -> String {
    let brand = HostInfo.sysctl("machdep.cpu.brand_string")
    if !brand.isEmpty { return brand }
    return HostInfo.sysctl("hw.model")
}

private func machine() -> String {
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
}

private func launchctlPath() -> String {
    if FileManager.default.isExecutableFile(atPath: "/bin/launchctl") {
        return "/bin/launchctl"
    }
    return "/usr/bin/launchctl"
}

private func actRunnerPath() -> String {
    var pid = ProcessInfo.processInfo.processIdentifier
    var chain: [String] = []
    for _ in 0..<12 {
        let path = HostInfo.command("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        chain.append("\(pid):\(path)")
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let got = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, ptr, size)
        }
        if got != size { break }
        let parent = pid_t(info.pbsi_ppid)
        if parent <= 1 { break }
        pid = parent
    }
    return "process chain (last below launchd is the Accessibility target): " + chain.joined(separator: " <- ")
}

/// Lets a plain reason string be the failure side of a Result in the bench harness.
extension String: Error {}
