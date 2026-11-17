// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class ServerTrustPolicyTests: XCTestCase {
    func testServerTrustRequiresAnSSLPolicyForTheHost() {
        XCTAssertTrue(ServerTrustPolicy.requiresHostSSLPolicy(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            host: "i.ytimg.com"
        ))
        XCTAssertFalse(ServerTrustPolicy.requiresHostSSLPolicy(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            host: "i.ytimg.com"
        ))
        XCTAssertFalse(ServerTrustPolicy.requiresHostSSLPolicy(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            host: "  "
        ))
        XCTAssertTrue(ServerTrustPolicy.needsHostSSLPolicy(authenticationMethod: NSURLAuthenticationMethodServerTrust))
        XCTAssertTrue(ServerTrustPolicy.canApplyHostSSLPolicy(host: "i.ytimg.com"))
    }

    func testSubresourceHostIsNotTheMainFrame() {
        XCTAssertFalse(ServerTrustPolicy.isMainFrameChallenge(
            protectionSpaceHost: "i.ytimg.com",
            mainFrameHost: "www.youtube.com"
        ))
        XCTAssertFalse(ServerTrustPolicy.isMainFrameChallenge(
            protectionSpaceHost: "i.ytimg.com",
            mainFrameHost: "youtube.com"
        ))
        XCTAssertTrue(ServerTrustPolicy.isMainFrameChallenge(
            protectionSpaceHost: "WWW.YouTube.com.",
            mainFrameHost: "www.youtube.com"
        ))
        XCTAssertTrue(ServerTrustPolicy.isMainFrameChallenge(
            protectionSpaceHost: "lab.example",
            mainFrameHost: nil
        ))
        XCTAssertFalse(ServerTrustPolicy.isMainFrameChallenge(
            protectionSpaceHost: "",
            mainFrameHost: nil
        ))
    }

    func testSystemTrustedCertificatesAreNotPromptedOrCredentialed() {
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: true,
                sessionAllowlisted: false,
                isMainFrame: true
            ),
            .performDefaultHandling
        )
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: true,
                sessionAllowlisted: true,
                isMainFrame: false
            ),
            .performDefaultHandling
        )
    }

    func testAllowlistUsesCredentialAndUntrustedSubresourcesDoNot() {
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: false,
                sessionAllowlisted: true,
                isMainFrame: true
            ),
            .useCredential
        )
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: false,
                sessionAllowlisted: true,
                isMainFrame: false
            ),
            .useCredential
        )
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: false,
                sessionAllowlisted: false,
                isMainFrame: true
            ),
            .prompt
        )
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: true,
                evaluatedTrusted: false,
                sessionAllowlisted: false,
                isMainFrame: false
            ),
            .performDefaultHandling
        )
        XCTAssertEqual(
            ServerTrustPolicy.disposition(
                isServerTrust: false,
                evaluatedTrusted: false,
                sessionAllowlisted: false,
                isMainFrame: true
            ),
            .performDefaultHandling
        )
    }
}
