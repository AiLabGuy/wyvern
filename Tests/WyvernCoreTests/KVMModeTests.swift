// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class KVMModeTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("bad url \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    func testNormalizationPortsCaseAndIgnoredParts() {
        XCTAssertEqual(
            KVMSiteList.normalizedOrigin(from: url("https://KVM.Example.LAN/console?view=1#top")),
            "https://kvm.example.lan"
        )
        XCTAssertEqual(
            KVMSiteList.normalizedOrigin(from: url("HTTPS://kvm.example.lan:443/a")),
            "https://kvm.example.lan"
        )
        XCTAssertEqual(
            KVMSiteList.normalizedOrigin(from: url("http://kvm.example.lan:80/a")),
            "http://kvm.example.lan"
        )
        XCTAssertEqual(
            KVMSiteList.normalizedOrigin(from: url("http://kvm.example.lan:443/a")),
            "http://kvm.example.lan:443"
        )
        XCTAssertEqual(
            KVMSiteList.normalizedOrigin(from: url("https://user:secret@kvm.example.lan:8443/path?q=1")),
            "https://kvm.example.lan:8443"
        )
        XCTAssertNil(KVMSiteList.normalizedOrigin(from: url("file:///tmp/page.html")))
        XCTAssertNil(KVMSiteList.normalizedOrigin(from: url("ftp://kvm.example.lan/")))
        XCTAssertNil(KVMSiteList.normalizedOrigin(from: url("about:blank")))
        XCTAssertNil(KVMSiteList.normalizedOrigin(from: url("http://")))
        XCTAssertNil(KVMSiteList.normalizedOrigin(from: url("http:///path")))
    }

    func testContainsAddingRemovingAndSortedOutput() {
        var list = KVMSiteList()
        XCTAssertFalse(list.contains(url("https://kvm.example.lan/console")))
        list = list.adding(url("https://kvm.example.lan/console?x=1"))
        list = list.adding(url("http://other.example.lan:8443/path"))
        list = list.adding(url("https://KVM.Example.LAN:443/other"))
        list = list.adding(url("file:///tmp/nope"))
        XCTAssertEqual(list.origins, [
            "http://other.example.lan:8443",
            "https://kvm.example.lan"
        ])
        XCTAssertTrue(list.contains(url("https://kvm.example.lan/different")))
        XCTAssertTrue(list.contains(url("https://kvm.example.lan:443/")))
        XCTAssertFalse(list.contains(url("https://kvm.example.lan:8443/")))
        XCTAssertFalse(list.contains(url("http://kvm.example.lan/")))
        XCTAssertFalse(list.contains(url("about:blank")))
        let removed = list.removing(url("https://kvm.example.lan/gone"))
        XCTAssertEqual(removed.origins, ["http://other.example.lan:8443"])
        XCTAssertEqual(list.removing(url("file:///tmp/nope")).origins, list.origins)
    }

    func testCodableRoundTripSortsAndDropsInvalid() throws {
        let decoded = try JSONDecoder().decode(
            KVMSiteList.self,
            from: Data(#"["https://b.example.lan/x","https://kvm.example.lan:443","not a url","ftp://files.example"]"#.utf8)
        )
        XCTAssertEqual(decoded.origins, ["https://b.example.lan", "https://kvm.example.lan"])
        let data = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(KVMSiteList.self, from: data)
        XCTAssertEqual(again, decoded)
        let object = try JSONSerialization.jsonObject(with: data) as? [String]
        XCTAssertEqual(object, ["https://b.example.lan", "https://kvm.example.lan"])
    }

    func testOldSettingsJSONWithoutKVMField() throws {
        let json = #"{"appearance":"light","searchEngineID":"duckduckgo","didChooseSearchEngine":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.appearance, .light)
        XCTAssertEqual(settings.searchEngineID, "duckduckgo")
        XCTAssertTrue(settings.didChooseSearchEngine)
        XCTAssertEqual(settings.kvmSites, KVMSiteList())
        XCTAssertTrue(settings.kvmSites.origins.isEmpty)

        let empty = try JSONDecoder().decode(AppSettings.self, from: Data(#"{}"#.utf8))
        XCTAssertEqual(empty.kvmSites.origins, [])

        var stored = AppSettings.firstLaunch
        stored.kvmSites = stored.kvmSites.adding(url("https://kvm.example.lan/ui"))
        let encoded = try JSONEncoder().encode(stored)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(roundTrip.kvmSites.origins, ["https://kvm.example.lan"])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"kvmSites\""))
    }

    func testOldSettingsStoreBlobWithoutKVMField() throws {
        let suite = "\(AppInfo.fallbackBundleIdentifier).kvm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"{"appearance":"light","didChooseSearchEngine":true,"developerToolsEnabled":false}"#
        defaults.set(Data(old.utf8), forKey: AppInfo.settingsDefaultsKey)
        let store = SettingsStore(defaults: defaults, key: AppInfo.settingsDefaultsKey)
        XCTAssertEqual(store.settings.appearance, .light)
        XCTAssertTrue(store.settings.didChooseSearchEngine)
        XCTAssertFalse(store.settings.developerToolsEnabled)
        XCTAssertTrue(store.settings.kvmSites.origins.isEmpty)
        store.update { $0.kvmSites = $0.kvmSites.adding(url("https://kvm.example.lan/")) }
        let reloaded = SettingsStore(defaults: defaults, key: AppInfo.settingsDefaultsKey)
        XCTAssertEqual(reloaded.settings.kvmSites.origins, ["https://kvm.example.lan"])
    }

    func testKeyRoutingTable() {
        let escape = KVMKeyModifiers([.control, .option, .command])
        let escapeShift = KVMKeyModifiers([.control, .option, .command, .shift])
        let command = KVMKeyModifiers.command
        let control = KVMKeyModifiers.control
        let option = KVMKeyModifiers.option
        let shift = KVMKeyModifiers.shift
        let none = KVMKeyModifiers()

        func route(
            _ key: UInt16,
            _ modifiers: KVMKeyModifiers,
            active: Bool = true,
            suspended: Bool = false
        ) -> KVMKeyDecision {
            KVMKeyRouting.route(
                keyCode: key,
                modifiers: modifiers,
                kvmActive: active,
                captureSuspended: suspended
            )
        }

        XCTAssertEqual(route(40, escape), .toggleCapture)
        XCTAssertEqual(route(40, escapeShift), .toggleCapture)
        XCTAssertEqual(route(40, escape, suspended: true), .toggleCapture)
        XCTAssertEqual(route(40, escape, active: false), .passToApp)
        XCTAssertEqual(route(40, escape, active: false, suspended: true), .passToApp)

        // Command-W, Command-Q, Command-T, Command-L, Command-N, Command-`, Control-Tab, Option.
        XCTAssertEqual(route(13, command), .sendToPage)
        XCTAssertEqual(route(12, command), .sendToPage)
        XCTAssertEqual(route(17, command), .sendToPage)
        XCTAssertEqual(route(37, command), .sendToPage)
        XCTAssertEqual(route(45, command), .sendToPage)
        XCTAssertEqual(route(50, command), .sendToPage)
        XCTAssertEqual(route(48, control), .sendToPage)
        XCTAssertEqual(route(0, option), .sendToPage)
        XCTAssertEqual(route(13, KVMKeyModifiers([.command, .shift])), .sendToPage)

        XCTAssertEqual(route(0, none), .passToApp)
        XCTAssertEqual(route(0, shift), .passToApp)
        XCTAssertEqual(route(49, none), .passToApp)

        XCTAssertEqual(route(13, command, suspended: true), .passToApp)
        XCTAssertEqual(route(48, control, suspended: true), .passToApp)
        XCTAssertEqual(route(0, none, suspended: true), .passToApp)
        XCTAssertEqual(route(12, command, active: false), .passToApp)
        XCTAssertEqual(route(48, control, active: false), .passToApp)
        XCTAssertEqual(route(40, command), .sendToPage)
        XCTAssertEqual(route(40, KVMKeyModifiers([.control, .command])), .sendToPage)
    }

    func testMediaScriptMarkers() {
        XCTAssertTrue(KVMMediaScript.source.contains("disablePictureInPicture = true"))
        XCTAssertTrue(KVMMediaScript.source.contains("disableRemotePlayback = true"))
        XCTAssertTrue(KVMMediaScript.source.contains("MutationObserver"))
        XCTAssertTrue(KVMMediaScript.source.contains("setActionHandler"))
        XCTAssertTrue(KVMMediaScript.source.contains("null"))
        XCTAssertTrue(KVMMediaScript.undo.contains("disconnect"))
    }
}
