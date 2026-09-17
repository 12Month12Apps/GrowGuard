//
//  LiveReadGateTests.swift
//  GrowGuardTests
//
//  The details screen shares the pool connection with background wake
//  reads. It may only request and save the live samples it asked for.
//

import Testing
import Foundation
@testable import GrowGuard

struct LiveReadGateTests {

    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("An unclaimed connection neither requests nor saves (background wake read)")
    func unclaimedIgnoresEverything() {
        var gate = LiveReadGate()

        let authenticated = gate.connectionAuthenticated(at: start)
        #expect(!authenticated)
        let received = gate.sampleReceived()
        #expect(!received)
    }

    @Test("A claimed connect requests once on authentication and saves the one answer")
    func claimedReadRequestsAndSavesOnce() {
        var gate = LiveReadGate()
        gate.claim(at: start)

        let firstAuthentication = gate.connectionAuthenticated(at: start.addingTimeInterval(2))
        #expect(firstAuthentication)
        let secondAuthentication = gate.connectionAuthenticated(at: start.addingTimeInterval(3))
        #expect(!secondAuthentication, "No second request for the same claim")
        let firstSample = gate.sampleReceived()
        #expect(firstSample)
        let secondSample = gate.sampleReceived()
        #expect(!secondSample, "A later sample belongs to someone else")
    }

    @Test("A dropped link before the answer re-requests after the pool reconnects")
    func reconnectReRequests() {
        var gate = LiveReadGate()
        gate.claim(at: start)
        let firstAuthentication = gate.connectionAuthenticated(at: start.addingTimeInterval(1))
        #expect(firstAuthentication)

        gate.connectionLost()

        let secondAuthentication = gate.connectionAuthenticated(at: start.addingTimeInterval(5))
        #expect(secondAuthentication)
        let sample = gate.sampleReceived()
        #expect(sample)
    }

    @Test("A claim expires, so a much later background wake is not treated as the screen's read")
    func claimExpires() {
        var gate = LiveReadGate()
        gate.claim(at: start)

        let muchLater = start.addingTimeInterval(LiveReadGate.claimLifetime + 1)
        let authenticated = gate.connectionAuthenticated(at: muchLater)
        #expect(!authenticated)
        let received = gate.sampleReceived()
        #expect(!received)
    }

    @Test("Losing an unclaimed connection keeps the gate closed")
    func lostWithoutClaimStaysClosed() {
        var gate = LiveReadGate()

        gate.connectionLost()

        let authenticated = gate.connectionAuthenticated(at: start)
        #expect(!authenticated)
    }

    @Test("Backgrounding releases the claim, so a wake read armed on entering background is not the screen's read")
    func releaseDropsClaim() {
        var gate = LiveReadGate()
        gate.claim(at: start)

        gate.release()

        let authenticated = gate.connectionAuthenticated(at: start.addingTimeInterval(5))
        #expect(!authenticated)
        let received = gate.sampleReceived()
        #expect(!received)
    }

    @Test("Releasing while awaiting the answer drops it too")
    func releaseWhileAwaitingSample() {
        var gate = LiveReadGate()
        gate.claim(at: start)
        let authenticated = gate.connectionAuthenticated(at: start.addingTimeInterval(1))
        #expect(authenticated)

        gate.release()
        gate.connectionLost()

        let reAuthenticated = gate.connectionAuthenticated(at: start.addingTimeInterval(5))
        #expect(!reAuthenticated)
        let received = gate.sampleReceived()
        #expect(!received)
    }
}
