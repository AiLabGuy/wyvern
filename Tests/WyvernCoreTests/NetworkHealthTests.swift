// SPDX-FileCopyrightText: 2026 Wyvern Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import WyvernCore

final class NetworkHealthTests: XCTestCase {
    func testPresentationMatchesTheSpec() {
        let good = HealthState.good.presentation
        XCTAssertEqual(good.glyphName, "circle")
        XCTAssertEqual(good.beatShapeID, "sharp-qrs")
        XCTAssertEqual(good.label, "GOOD")
        XCTAssertEqual(good.beatsPerMinute, 60)
        XCTAssertEqual(good.barSweepPointsPerSecond, 25)
        XCTAssertEqual(good.panelSweepPointsPerSecond, 50)
        XCTAssertEqual(good.lightHex, "#14834A")
        XCTAssertEqual(good.darkHex, "#3DD68C")

        let fair = HealthState.fair.presentation
        XCTAssertEqual(fair.glyphName, "triangle")
        XCTAssertEqual(fair.beatShapeID, "wide-stretched")
        XCTAssertEqual(fair.beatsPerMinute, 40)
        XCTAssertEqual(fair.beatWidthScale, 1.5)
        XCTAssertEqual(fair.barSweepPointsPerSecond, 25)
        XCTAssertEqual(fair.panelSweepPointsPerSecond, 50)
        XCTAssertEqual(fair.lightHex, "#9A6A00")
        XCTAssertEqual(fair.darkHex, "#F2C14E")

        let poor = HealthState.poor.presentation
        XCTAssertEqual(poor.glyphName, "cross")
        XCTAssertEqual(poor.beatShapeID, "jagged-spike")
        XCTAssertEqual(poor.beatsPerMinute, 150)
        XCTAssertEqual(poor.intervalJitterFraction, 0.30)
        XCTAssertEqual(poor.beatHeightJitterFraction, 0.30)
        XCTAssertEqual(poor.barSweepPointsPerSecond, 40)
        XCTAssertEqual(poor.panelSweepPointsPerSecond, 40)
        XCTAssertEqual(poor.lightHex, "#C62828")
        XCTAssertEqual(poor.darkHex, "#FF6B6B")

        let offline = HealthState.offline.presentation
        XCTAssertEqual(offline.glyphName, "dash")
        XCTAssertEqual(offline.beatShapeID, "flatline")
        XCTAssertEqual(offline.label, "OFFLINE")
        XCTAssertEqual(offline.beatsPerMinute, 0)
        XCTAssertEqual(offline.barSweepPointsPerSecond, 10)
        XCTAssertEqual(offline.headPulseHertz, 0.5)
        XCTAssertEqual(offline.lightHex, "#6E6E6E")
        XCTAssertEqual(offline.darkHex, "#8A8A8A")

        XCTAssertEqual(HealthState.unknown.glyphName, "none")
        XCTAssertEqual(HealthState.unknown.beatShapeID, "idle")
        XCTAssertEqual(HealthLimits.colorCrossfade, 0.2)
    }

    func testRTTBoundaries() {
        XCTAssertEqual(classify(rtts: [ms(79)]), .good)
        XCTAssertEqual(classify(rtts: [ms(80)]), .fair)
        XCTAssertEqual(classify(rtts: [ms(250)]), .fair)
        XCTAssertEqual(classify(rtts: [ms(251)]), .poor)

        XCTAssertEqual(committedState(rtt: ms(79)), .good)
        XCTAssertEqual(committedState(rtt: ms(80)), .fair)
        XCTAssertEqual(committedState(rtt: ms(250)), .fair)
        XCTAssertEqual(committedState(rtt: ms(251)), .poor)
    }

    func testLossBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)
        var atTwoPercent = HealthWindow()
        for _ in 0..<49 {
            atTwoPercent.add(HealthSample(timestamp: now, rtt: ms(20), lost: false), now: now)
        }
        atTwoPercent.add(HealthSample(timestamp: now, rtt: nil, lost: true), now: now)
        let two = atTwoPercent.stats(at: now)
        XCTAssertEqual(two.lossPercent, 2, accuracy: 0.000_001)
        XCTAssertEqual(HealthClassifier.classify(two), .good)

        var atTwoPointOne = HealthWindow()
        for _ in 0..<979 {
            atTwoPointOne.add(HealthSample(timestamp: now, rtt: ms(20), lost: false), now: now)
        }
        for _ in 0..<21 {
            atTwoPointOne.add(HealthSample(timestamp: now, rtt: nil, lost: true), now: now)
        }
        let over = atTwoPointOne.stats(at: now)
        XCTAssertEqual(over.lossPercent, 2.1, accuracy: 0.000_001)
        XCTAssertEqual(HealthClassifier.classify(over), .poor)
    }

    func testJitterMathSkipsLostSamplesAndUsesTheThreshold() {
        let now = Date(timeIntervalSince1970: 20_000)
        var window = HealthWindow()
        let series: [(TimeInterval?, Bool)] = [
            (ms(10), false),
            (nil, true),
            (ms(30), false),
            (ms(20), false)
        ]
        for (offset, sample) in series.enumerated() {
            let time = now.addingTimeInterval(TimeInterval(offset))
            window.add(HealthSample(timestamp: time, rtt: sample.0, lost: sample.1), now: time)
        }
        let stats = window.stats(at: now.addingTimeInterval(3))
        XCTAssertEqual(stats.jitter ?? -1, ms(15), accuracy: 0.000_001)
        XCTAssertEqual(stats.meanRTT ?? -1, ms(20), accuracy: 0.000_001)
        XCTAssertEqual(stats.medianRTT ?? -1, ms(20), accuracy: 0.000_001)
        XCTAssertEqual(stats.lostCount, 1)
        XCTAssertEqual(stats.receivedCount, 3)

        XCTAssertEqual(classify(rtts: [0, ms(100)]), .good)
        XCTAssertEqual(classify(rtts: [0, ms(100.1)]), .poor)
    }

    func testEvenMedianAndNilJitterUntilTwoReplies() {
        let now = Date(timeIntervalSince1970: 30_000)
        var window = HealthWindow()
        window.add(HealthSample(timestamp: now, rtt: ms(10), lost: false), now: now)
        var stats = window.stats(at: now)
        XCTAssertNil(stats.jitter)
        XCTAssertEqual(stats.medianRTT ?? -1, ms(10), accuracy: 0.000_001)
        window.add(HealthSample(timestamp: now.addingTimeInterval(1), rtt: ms(30), lost: false), now: now)
        stats = window.stats(at: now.addingTimeInterval(1))
        XCTAssertEqual(stats.medianRTT ?? -1, ms(20), accuracy: 0.000_001)
        XCTAssertEqual(stats.jitter ?? -1, ms(20), accuracy: 0.000_001)
    }

    func testWindowExpiresAtSixtySeconds() {
        var window = HealthWindow(duration: 60)
        let start = Date(timeIntervalSince1970: 40_000)
        window.add(HealthSample(timestamp: start, rtt: ms(10), lost: false), now: start)
        let later = start.addingTimeInterval(10)
        window.add(HealthSample(timestamp: later, rtt: ms(50), lost: false), now: later)

        XCTAssertEqual(window.stats(at: start.addingTimeInterval(59)).sampleCount, 2)
        let onTheBoundary = window.stats(at: start.addingTimeInterval(60))
        XCTAssertEqual(onTheBoundary.sampleCount, 1)
        XCTAssertEqual(onTheBoundary.medianRTT ?? -1, ms(50), accuracy: 0.000_001)
        XCTAssertEqual(window.stats(at: start.addingTimeInterval(70)).sampleCount, 0)
        XCTAssertEqual(HealthClassifier.classify(window.stats(at: start.addingTimeInterval(70))), .unknown)
    }

    func testHysteresisOneBadSampleDoesNotChangeState() {
        var now = Date(timeIntervalSince1970: 50_000)
        var machine = HealthStateMachine(clock: { now })
        machine.begin(at: now)
        let first = machine.record(rtt: ms(251), lost: false, at: now)
        XCTAssertEqual(first.state, .unknown)

        now = now.addingTimeInterval(1)
        let second = machine.record(rtt: ms(251), lost: false, at: now)
        XCTAssertEqual(second.state, .poor)

        var stable = Date(timeIntervalSince1970: 60_000)
        var held = HealthStateMachine(clock: { stable })
        for index in 0..<48 {
            stable = Date(timeIntervalSince1970: 60_000 + TimeInterval(index))
            held.record(rtt: ms(20), lost: false, at: stable)
        }
        XCTAssertEqual(held.state, .good)
        stable = stable.addingTimeInterval(1)
        let crossing = held.record(rtt: nil, lost: true, at: stable)
        XCTAssertGreaterThan(crossing.stats.lossPercent, 2)
        XCTAssertEqual(crossing.state, .good)
        stable = stable.addingTimeInterval(1)
        XCTAssertEqual(held.record(rtt: nil, lost: true, at: stable).state, .poor)

        var spiked = Date(timeIntervalSince1970: 70_000)
        var calm = HealthStateMachine(clock: { spiked })
        calm.record(rtt: ms(20), lost: false, at: spiked)
        spiked = spiked.addingTimeInterval(1)
        calm.record(rtt: ms(20), lost: false, at: spiked)
        spiked = spiked.addingTimeInterval(1)
        XCTAssertEqual(calm.record(rtt: ms(251), lost: false, at: spiked).state, .good)
    }

    func testOfflineAfterThreeSecondsAndRecovery() {
        var now = Date(timeIntervalSince1970: 80_000)
        var machine = HealthStateMachine(clock: { now })
        machine.begin(at: now)
        XCTAssertEqual(machine.advance(to: now.addingTimeInterval(2.9)).state, .unknown)
        XCTAssertEqual(machine.advance(to: now.addingTimeInterval(3)).state, .offline)

        let first = machine.record(rtt: ms(20), lost: false, at: now.addingTimeInterval(3))
        XCTAssertEqual(first.state, .offline)
        let second = machine.record(rtt: ms(20), lost: false, at: now.addingTimeInterval(4))
        XCTAssertEqual(second.state, .good)

        machine.noteNoRoute(at: now.addingTimeInterval(4))
        XCTAssertEqual(machine.state, .offline)
    }

    func testEchoMatchesIdentifierAndSequence() {
        let request = ICMPPackets.echo(family: .v4, identifier: 1, sequence: 1, payload: [])
        XCTAssertEqual(request, [0x08, 0x00, 0xF7, 0xFD, 0x00, 0x01, 0x00, 0x01])
        var reply = request
        reply[0] = 0
        XCTAssertTrue(ICMPPackets.matchesEchoReply(reply, family: .v4, identifier: 1, sequence: 1))
        XCTAssertFalse(ICMPPackets.matchesEchoReply(reply, family: .v4, identifier: 1, sequence: 2))
        XCTAssertFalse(ICMPPackets.matchesEchoReply(reply, family: .v4, identifier: 9, sequence: 1))

        var wrapped = [UInt8](repeating: 0, count: 20)
        wrapped[0] = 0x45
        wrapped.append(contentsOf: reply)
        XCTAssertTrue(ICMPPackets.matchesEchoReply(wrapped, family: .v4, identifier: 1, sequence: 1))
    }

    func testTimeExceededQuoteCarriesTheDestinationPort() {
        var packet = [UInt8](repeating: 0, count: 36)
        packet[0] = 11
        packet[8] = 0x45
        packet[30] = 0x82
        packet[31] = 0x9A
        let exceeded = ICMPPackets.errorQuote(packet, family: .v4)
        XCTAssertEqual(exceeded?.kind, .timeExceeded)
        XCTAssertEqual(exceeded?.destinationPort, 33_434)

        packet[0] = 3
        packet[1] = 3
        let closed = ICMPPackets.errorQuote(packet, family: .v4)
        XCTAssertEqual(closed?.kind, .portUnreachable)
        XCTAssertEqual(closed?.destinationPort, 33_434)
    }

    func testTracerouteIsUnavailableWithoutAResolutionOrAReceiveSocket() {
        let unresolved = Traceroute(driver: TraceDriver(
            lookup: { _ in nil },
            prepare: { _ in
                XCTFail("prepare must not run when the host did not resolve")
                return nil
            },
            close: {},
            probe: { _, _, _, _ in
                XCTFail("probe must not run when the host did not resolve")
                return .timeout
            }
        ))
        XCTAssertEqual(
            unresolved.execute(host: "docs.example.org", maxHops: 30, perHopTimeout: 1),
            .unavailable(.hostDidNotResolve)
        )

        var probes = 0
        let blocked = Traceroute(driver: TraceDriver(
            lookup: { _ in SystemDNS.numeric("203.0.113.42") },
            prepare: { _ in .receiveUnavailable },
            close: {},
            probe: { _, _, _, _ in
                probes += 1
                return .timeout
            }
        ))
        XCTAssertEqual(
            blocked.execute(host: "docs.example.org", maxHops: 30, perHopTimeout: 1),
            .unavailable(.receiveUnavailable)
        )
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(TraceError.receiveUnavailable.message, "Unprivileged ICMP receive is not available.")
    }

    func testTracerouteHopLoopPortsTTLCancelAndReach() {
        var sent: [(ttl: Int, port: UInt16, timeout: TimeInterval)] = []
        let open = Traceroute(driver: TraceDriver(
            lookup: { _ in SystemDNS.numeric("203.0.113.42") },
            prepare: { _ in nil },
            close: {},
            probe: { ttl, port, timeout, _ in
                sent.append((ttl, port, timeout))
                return .timeout
            }
        ))
        let full = open.execute(host: "docs.example.org", maxHops: 40, perHopTimeout: 1)
        XCTAssertEqual(sent.map(\.ttl), Array(1...30))
        XCTAssertEqual(sent.map(\.port), (0..<30).map { UInt16(33_434 + $0) })
        XCTAssertTrue(sent.allSatisfy { $0.timeout == 1 })
        if case .hops(let hops) = full {
            XCTAssertEqual(hops.count, 30)
            XCTAssertEqual(hops[0].ttl, 1)
            XCTAssertNil(hops[0].ip)
            XCTAssertNil(hops[0].rtt)
        } else {
            XCTFail("expected a hop list")
        }

        var reachedTracer: Traceroute!
        reachedTracer = Traceroute(driver: TraceDriver(
            lookup: { _ in SystemDNS.numeric("203.0.113.42") },
            prepare: { _ in nil },
            close: {},
            probe: { ttl, _, _, _ in
                if ttl == 2 { reachedTracer.cancel() }
                if ttl == 4 { return .reached(ip: "203.0.113.42", rtt: 0.04) }
                return .timeExceeded(ip: "203.0.113.1", rtt: 0.01)
            }
        ))
        XCTAssertEqual(
            reachedTracer.execute(host: "docs.example.org", maxHops: 30, perHopTimeout: 1),
            .cancelled
        )

        let finished = Traceroute(driver: TraceDriver(
            lookup: { _ in SystemDNS.numeric("203.0.113.42") },
            prepare: { _ in nil },
            close: {},
            probe: { ttl, _, _, _ in
                if ttl == 3 { return .reached(ip: "203.0.113.42", rtt: ms(40)) }
                return .timeExceeded(ip: "203.0.113.1", rtt: ms(10))
            }
        ))
        if case .hops(let hops) = finished.execute(host: "docs.example.org", maxHops: 30, perHopTimeout: 1) {
            XCTAssertEqual(hops.count, 3)
            XCTAssertEqual(hops[2].ip, "203.0.113.42")
            XCTAssertEqual(hops[2].rtt ?? -1, ms(40), accuracy: 0.000_001)
        } else {
            XCTFail("expected the trace to stop on the destination")
        }
    }

    func testServicePublishesTheVisibleHostOnTheInjectedDelivery() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 90_000))
        let icmp = FakeProber(kind: .icmp)
        icmp.outcome = .response(rtt: ms(164), resolvedIP: nil)
        let tcp = FakeProber(kind: .tcp(port: 443))
        let resolver = ScriptedResolver(ip: "203.0.113.42")
        var deliveries = 0
        let service = makeService(
            clock: clock,
            icmp: icmp,
            tcp: tcp,
            resolver: resolver,
            deliver: { deliveries += 1; $0() }
        )
        var snapshots: [NetworkHealthSnapshot] = []
        service.onSnapshot = { snapshots.append($0) }

        service.start(host: " Docs.Example.ORG. ", scheme: "HTTPS")
        XCTAssertEqual(icmp.calls.map(\.host), ["docs.example.org"])
        XCTAssertEqual(icmp.calls[0].timeout, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(resolver.hosts, ["docs.example.org"])
        XCTAssertEqual(service.currentSnapshot.resolvedIP, "203.0.113.42")
        XCTAssertNil(service.currentSnapshot.protocolName)
        XCTAssertEqual(service.currentSnapshot.probeKind, .icmp)
        XCTAssertEqual(service.currentSnapshot.state, .unknown)
        XCTAssertEqual(deliveries, snapshots.count)
        XCTAssertGreaterThan(deliveries, 0)

        clock.advance(by: 1)
        XCTAssertEqual(service.currentSnapshot.state, .fair)
        XCTAssertEqual(service.currentSnapshot.samples.count, 2)
        XCTAssertEqual(
            service.currentSnapshot.accessibilityLabel,
            "Network health: Fair, 164 ms"
        )
        XCTAssertFalse(service.currentSnapshot.announcePolitely)

        service.protocolName = "HTTP/2"
        XCTAssertEqual(service.currentSnapshot.protocolName, "HTTP/2")
        XCTAssertEqual(icmp.calls.count, 2)

        service.start(host: "example.com", scheme: "https")
        XCTAssertEqual(icmp.calls.last?.host, "example.com")
        XCTAssertTrue(resolver.hosts.allSatisfy { $0 == "docs.example.org" || $0 == "example.com" })
        XCTAssertEqual(service.currentSnapshot.host, "example.com")
        XCTAssertEqual(service.currentSnapshot.samples.count, 1)
        XCTAssertNil(service.currentSnapshot.protocolName)
    }

    func testVisibilityGraceStopsProbingAfterThirtySeconds() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 100_000))
        let icmp = FakeProber(kind: .icmp)
        let service = makeService(clock: clock, icmp: icmp, tcp: FakeProber(kind: .tcp(port: 443)))
        service.start(host: "docs.example.org", scheme: "https")
        service.visibilityChanged(visible: false)
        clock.advance(by: 29)
        XCTAssertEqual(icmp.calls.count, 30)
        clock.advance(by: 1)
        XCTAssertEqual(icmp.calls.count, 30)
        clock.advance(by: 10)
        XCTAssertEqual(icmp.calls.count, 30)

        service.visibilityChanged(visible: true)
        XCTAssertEqual(icmp.calls.count, 31)
        clock.advance(by: 2)
        XCTAssertEqual(icmp.calls.count, 33)
    }

    func testShowingTheWindowBeforeGraceEndsKeepsProbing() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 110_000))
        let icmp = FakeProber(kind: .icmp)
        let service = makeService(clock: clock, icmp: icmp, tcp: FakeProber(kind: .tcp(port: 443)))
        service.start(host: "docs.example.org", scheme: "https")
        service.visibilityChanged(visible: false)
        clock.advance(by: 10)
        XCTAssertEqual(icmp.calls.count, 11)
        service.visibilityChanged(visible: true)
        clock.advance(by: 25)
        XCTAssertEqual(icmp.calls.count, 36)
    }

    func testEnabledFlagStopsAndResumesProbing() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 120_000))
        let icmp = FakeProber(kind: .icmp)
        let service = makeService(
            clock: clock,
            icmp: icmp,
            tcp: FakeProber(kind: .tcp(port: 443)),
            enabled: false
        )
        service.start(host: "docs.example.org", scheme: "https")
        XCTAssertEqual(icmp.calls.count, 0)
        XCTAssertFalse(service.currentSnapshot.enabled)

        service.enabled = true
        XCTAssertEqual(icmp.calls.count, 1)
        service.enabled = false
        clock.advance(by: 5)
        XCTAssertEqual(icmp.calls.count, 1)
        service.enabled = true
        XCTAssertEqual(icmp.calls.count, 2)
        XCTAssertEqual(icmp.calls.map(\.host), ["docs.example.org", "docs.example.org"])
    }

    func testTimeoutsGoOfflineThroughTheService() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 130_000))
        let icmp = FakeProber(kind: .icmp)
        icmp.outcome = .timeout(resolvedIP: nil)
        let service = makeService(clock: clock, icmp: icmp, tcp: FakeProber(kind: .tcp(port: 443)))
        var announced: [HealthState] = []
        service.onSnapshot = { snapshot in
            if snapshot.announcePolitely {
                announced.append(snapshot.state)
            }
        }
        service.start(host: "docs.example.org", scheme: "https")
        clock.advance(by: 3)
        XCTAssertEqual(service.currentSnapshot.state, .offline)
        XCTAssertEqual(service.currentSnapshot.stats.lossPercent, 100, accuracy: 0.000_001)
        XCTAssertEqual(announced, [.poor, .offline])
        XCTAssertTrue(service.currentSnapshot.announcePolitely)
    }

    func testFallbackWhenTheICMPSocketCannotOpen() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 140_000))
        let icmp = FakeProber(kind: .icmp)
        icmp.prepareResult = false
        let tcp = FakeProber(kind: .tcp(port: 1))
        let ports = PortList()
        let service = makeService(clock: clock, icmp: icmp, tcp: tcp, ports: ports)
        service.start(host: "docs.example.org", scheme: "https")
        XCTAssertEqual(icmp.calls.count, 0)
        XCTAssertEqual(tcp.calls.count, 1)
        XCTAssertEqual(ports.values, [443])
        XCTAssertEqual(service.currentSnapshot.probeKind, .tcp(port: 443))

        let httpICMP = FakeProber(kind: .icmp)
        httpICMP.prepareResult = false
        let httpTCP = FakeProber(kind: .tcp(port: 1))
        let httpPorts = PortList()
        let http = makeService(
            clock: ManualClock(now: clock.now),
            icmp: httpICMP,
            tcp: httpTCP,
            ports: httpPorts
        )
        http.start(host: "docs.example.org", scheme: "http")
        XCTAssertEqual(httpPorts.values, [80])
        XCTAssertEqual(http.currentSnapshot.probeKind, .tcp(port: 80))
    }

    func testFallbackAfterThreeICMPSendFailuresWhenTCPSucceeds() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 150_000))
        let icmp = FakeProber(kind: .icmp)
        icmp.outcome = .sendFailed
        let tcp = FakeProber(kind: .tcp(port: 443))
        tcp.outcome = .response(rtt: ms(20), resolvedIP: nil)
        let service = makeService(clock: clock, icmp: icmp, tcp: tcp)
        service.start(host: "docs.example.org", scheme: "https")
        clock.advance(by: 2)
        XCTAssertEqual(icmp.calls.count, 3)
        XCTAssertEqual(tcp.calls.count, 1)
        XCTAssertEqual(service.currentSnapshot.probeKind, .tcp(port: 443))
        clock.advance(by: 1)
        XCTAssertEqual(icmp.calls.count, 3)
        XCTAssertEqual(tcp.calls.count, 2)
        XCTAssertTrue(tcp.calls.allSatisfy { $0.host == "docs.example.org" })
    }

    func testNoFallbackWhenTCPDoesNotSucceed() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 160_000))
        let icmp = FakeProber(kind: .icmp)
        icmp.outcome = .sendFailed
        let tcp = FakeProber(kind: .tcp(port: 443))
        tcp.outcome = .timeout(resolvedIP: nil)
        let service = makeService(clock: clock, icmp: icmp, tcp: tcp)
        service.start(host: "docs.example.org", scheme: "https")
        clock.advance(by: 2)
        XCTAssertEqual(tcp.calls.count, 1)
        XCTAssertEqual(service.currentSnapshot.probeKind, .icmp)
        clock.advance(by: 1)
        XCTAssertEqual(icmp.calls.count, 4)
        XCTAssertEqual(tcp.calls.count, 1)
    }

    func testDeliverOnMainRunsOnTheMainQueue() {
        let ready = expectation(description: "main delivery")
        DispatchQueue.global(qos: .userInitiated).async {
            NetworkHealthService.deliverOnMain {
                XCTAssertTrue(Thread.isMainThread)
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 1)
    }

    private func classify(rtts: [TimeInterval]) -> HealthState {
        var window = HealthWindow()
        let now = Date(timeIntervalSince1970: 1)
        for (index, rtt) in rtts.enumerated() {
            let time = now.addingTimeInterval(TimeInterval(index))
            window.add(HealthSample(timestamp: time, rtt: rtt, lost: false), now: time)
        }
        return HealthClassifier.classify(window.stats(at: now.addingTimeInterval(TimeInterval(rtts.count))))
    }

    private func committedState(rtt: TimeInterval) -> HealthState {
        var now = Date(timeIntervalSince1970: 1)
        var machine = HealthStateMachine(clock: { now })
        machine.record(rtt: rtt, lost: false, at: now)
        now = now.addingTimeInterval(1)
        return machine.record(rtt: rtt, lost: false, at: now).state
    }

    private func makeService(
        clock: ManualClock,
        icmp: FakeProber,
        tcp: FakeProber,
        resolver: ScriptedResolver = ScriptedResolver(ip: "203.0.113.42"),
        ports: PortList? = nil,
        enabled: Bool = true,
        deliver: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> NetworkHealthService {
        let capturedTCP = tcp
        return NetworkHealthService(
            clock: clock,
            icmp: icmp,
            tcpFactory: { port in
                if let ports {
                    ports.values.append(port)
                    capturedTCP.kind = .tcp(port: port)
                }
                return capturedTCP
            },
            resolver: resolver,
            traceroute: Traceroute(driver: TraceDriver(
                lookup: { _ in nil },
                prepare: { _ in .receiveUnavailable },
                close: {},
                probe: { _, _, _, _ in .timeout }
            )),
            enabled: enabled,
            deliver: deliver
        )
    }
}

private func ms(_ value: Double) -> TimeInterval {
    value / 1_000
}

private final class ManualClock: HealthClock {
    final class Token: HealthCancellable {
        var cancelled = false
        var block: (() -> Void)?
        func cancel() {
            cancelled = true
            block = nil
        }
    }

    private struct Entry {
        var due: Date
        var order: Int
        var token: Token
    }

    var now: Date
    private var entries: [Entry] = []
    private var order = 0

    init(now: Date) {
        self.now = now
    }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> any HealthCancellable {
        let token = Token()
        token.block = block
        order += 1
        entries.append(Entry(due: now.addingTimeInterval(delay), order: order, token: token))
        return token
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            var chosen: Int?
            for index in entries.indices {
                let entry = entries[index]
                if entry.token.cancelled || entry.due > target { continue }
                if let current = chosen {
                    let best = entries[current]
                    if entry.due < best.due || (entry.due == best.due && entry.order < best.order) {
                        chosen = index
                    }
                } else {
                    chosen = index
                }
            }
            guard let index = chosen else {
                now = target
                entries.removeAll { $0.token.cancelled }
                return
            }
            now = entries[index].due
            let token = entries[index].token
            entries.remove(at: index)
            if !token.cancelled {
                token.block?()
            }
        }
    }
}

private final class FakeProber: Prober {
    var kind: ProbeKind
    var prepareResult = true
    var outcome: ProbeOutcome = .response(rtt: 0.02, resolvedIP: nil)
    var calls: [(host: String, timeout: TimeInterval)] = []

    init(kind: ProbeKind) {
        self.kind = kind
    }

    func prepare() -> Bool {
        prepareResult
    }

    func probe(host: String, timeout: TimeInterval, completion: @escaping (ProbeAttempt) -> Void) {
        calls.append((host, timeout))
        completion(ProbeAttempt(outcome: outcome, kind: kind))
    }

    func cancel() {}
}

private final class PortList {
    var values: [UInt16] = []
}

private final class ScriptedResolver: HostResolving {
    var ip: String?
    var hosts: [String] = []

    init(ip: String?) {
        self.ip = ip
    }

    func resolve(_ host: String) -> String? {
        hosts.append(host)
        return ip
    }
}
