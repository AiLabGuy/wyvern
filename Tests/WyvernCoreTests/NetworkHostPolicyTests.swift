// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class NetworkHostPolicyTests: XCTestCase {
    func testPublicNamesAndAddresses() {
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("updates.example.invalid"))
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("cdn.example.invalid"))
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("1.1.1.1"))
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("2001:db8::1"))
        XCTAssertFalse(NetworkHostPolicy.isLoopbackOrLinkLocal("updates.example.invalid"))
    }

    func testLoopbackLinkLocalAndAmbiguousForms() {
        let hosts = [
            "127.0.0.1", "127.0.0.2", "0.0.0.0", "169.254.169.254",
            "::1", "[::1]", "::", "fe80::1", "::ffff:127.0.0.1",
            "localhost", "localhost.localdomain", "printer.localhost",
            "0177.0.0.1", "127.1", "2130706433", "0x7f000001", "999.1.1.1"
        ]
        for host in hosts {
            XCTAssertTrue(NetworkHostPolicy.isLoopbackOrLinkLocal(host), host)
            XCTAssertTrue(NetworkHostPolicy.isNonPublic(host), host)
        }
    }

    func testPrivateRangesAreNotLoopback() {
        let hosts = ["10.1.2.3", "192.168.0.10", "172.16.0.4", "100.64.0.1", "nas.local", "host.home.arpa"]
        for host in hosts {
            XCTAssertTrue(NetworkHostPolicy.isNonPublic(host), host)
            XCTAssertFalse(NetworkHostPolicy.isLoopbackOrLinkLocal(host), host)
        }
        XCTAssertTrue(NetworkHostPolicy.isNonPublic("::ffff:10.0.0.1"))
        XCTAssertTrue(NetworkHostPolicy.isNonPublic("fd00::1"))
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("::ffff:1.1.1.1"))
        XCTAssertTrue(NetworkHostPolicy.isUserSpecifiedLAN("10.1.2.3"))
        XCTAssertTrue(NetworkHostPolicy.isUserSpecifiedLAN("100.64.0.1"))
        XCTAssertTrue(NetworkHostPolicy.isUserSpecifiedLAN("fd00::1"))
        XCTAssertTrue(NetworkHostPolicy.isUserSpecifiedLAN("::ffff:192.168.0.10"))
        XCTAssertFalse(NetworkHostPolicy.isUserSpecifiedLAN("224.0.0.1"))
        XCTAssertFalse(NetworkHostPolicy.isUserSpecifiedLAN("192.0.2.1"))
        XCTAssertFalse(NetworkHostPolicy.isUserSpecifiedLAN("nas.local"))
        XCTAssertTrue(NetworkHostPolicy.isLocalOnlyName("nas.local"))
        XCTAssertFalse(NetworkHostPolicy.isLocalOnlyName("10.1.2.3"))
        XCTAssertFalse(NetworkHostPolicy.isNonPublic("2001:db8::1.2.3.4"))
    }
}
