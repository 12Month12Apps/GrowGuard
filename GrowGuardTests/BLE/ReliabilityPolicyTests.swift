//
//  ReliabilityPolicyTests.swift
//  GrowGuardTests
//
//  Pure unit tests for the reconnect policy building blocks — no transport,
//  no scheduler, just decisions.
//

import Testing
import Foundation
import CoreBluetooth
@testable import GrowGuard

struct ReconnectPolicyTests {

    let policy = ReconnectPolicy()

    @Test("Sensor-initiated disconnects retry quickly: 1s then 2s")
    func peripheralDisconnectedSchedule() {
        #expect(policy.decision(attempt: 1, reason: .peripheralDisconnected) == .retry(after: 1))
        #expect(policy.decision(attempt: 2, reason: .peripheralDisconnected) == .retry(after: 2))
        #expect(policy.decision(attempt: 3, reason: .peripheralDisconnected) == .giveUp)
    }

    @Test("Connection-establishment failures back off harder: 2s then 4s")
    func connectionFailureSchedule() {
        for reason in [DisconnectReason.connectionTimeout, .failedToConnect, .unknown] {
            #expect(policy.decision(attempt: 1, reason: reason) == .retry(after: 2))
            #expect(policy.decision(attempt: 2, reason: reason) == .retry(after: 4))
            #expect(policy.decision(attempt: 3, reason: reason) == .giveUp)
        }
    }

    @Test("App watchdog timeouts keep the historical 1s/2s schedule")
    func appTimeoutSchedule() {
        #expect(policy.decision(attempt: 1, reason: .appTimeout) == .retry(after: 1))
        #expect(policy.decision(attempt: 2, reason: .appTimeout) == .retry(after: 2))
        #expect(policy.decision(attempt: 3, reason: .appTimeout) == .giveUp)
    }

    @Test("Bluetooth-off never burns retry attempts")
    func bluetoothUnavailableWaits() {
        #expect(policy.decision(attempt: 1, reason: .bluetoothUnavailable) == .waitForBluetooth)
        #expect(policy.decision(attempt: 99, reason: .bluetoothUnavailable) == .waitForBluetooth)
    }

    @Test("Auto-reconnect delay equals the first-attempt delay per reason")
    func reconnectDelayPerReason() {
        #expect(policy.reconnectDelay(reason: .clean) == 1)
        #expect(policy.reconnectDelay(reason: .peripheralDisconnected) == 1)
        #expect(policy.reconnectDelay(reason: .connectionTimeout) == 2)
        #expect(policy.reconnectDelay(reason: .unknown) == 2)
    }

    @Test("DisconnectReason maps CoreBluetooth error codes")
    func reasonFromError() {
        #expect(DisconnectReason(error: nil) == .clean)
        #expect(DisconnectReason(error: NSError(domain: CBErrorDomain, code: CBError.peripheralDisconnected.rawValue)) == .peripheralDisconnected)
        #expect(DisconnectReason(error: NSError(domain: CBErrorDomain, code: CBError.connectionTimeout.rawValue)) == .connectionTimeout)
        #expect(DisconnectReason(error: NSError(domain: CBErrorDomain, code: 999)) == .unknown)
        #expect(DisconnectReason(error: NSError(domain: NSURLErrorDomain, code: -1001)) == .unknown)
    }
}

struct DisconnectLoopGuardTests {

    @Test("Five no-progress disconnects inside the window trip the guard")
    func tripsOnStalledDisconnects() {
        var loopGuard = DisconnectLoopGuard()
        for i in 0..<5 {
            #expect(!loopGuard.isLooping(at: TimeInterval(i * 10)))
            loopGuard.recordDisconnect(at: TimeInterval(i * 10), historyIndex: 0)
        }
        #expect(loopGuard.isLooping(at: 40))
    }

    @Test("Disconnects with advancing history index never trip the guard")
    func progressResetsTheStreak() {
        var loopGuard = DisconnectLoopGuard()
        for i in 0..<10 {
            loopGuard.recordDisconnect(at: TimeInterval(i * 5), historyIndex: (i + 1) * 100)
            #expect(!loopGuard.isLooping(at: TimeInterval(i * 5)))
        }
    }

    @Test("A single progressing disconnect resets an almost-tripped streak")
    func progressClearsAccumulatedStalls() {
        var loopGuard = DisconnectLoopGuard()
        for i in 0..<4 {
            loopGuard.recordDisconnect(at: TimeInterval(i), historyIndex: 0)
        }
        loopGuard.recordDisconnect(at: 4, historyIndex: 50) // progress!
        for i in 5..<9 {
            loopGuard.recordDisconnect(at: TimeInterval(i), historyIndex: 50)
        }
        #expect(!loopGuard.isLooping(at: 9), "Only 4 stalled drops since the progress reset")
        loopGuard.recordDisconnect(at: 9.5, historyIndex: 50)
        #expect(loopGuard.isLooping(at: 9.5))
    }

    @Test("Old disconnects age out of the window")
    func windowExpiry() {
        var loopGuard = DisconnectLoopGuard(maxReconnectsWithoutProgress: 3, window: 60)
        loopGuard.recordDisconnect(at: 0, historyIndex: 0)
        loopGuard.recordDisconnect(at: 10, historyIndex: 0)
        // Third stalled drop, but the first one is 100s old by now
        loopGuard.recordDisconnect(at: 100, historyIndex: 0)
        #expect(!loopGuard.isLooping(at: 100))
    }

    @Test("reset() clears all state")
    func resetClears() {
        var loopGuard = DisconnectLoopGuard()
        for i in 0..<5 {
            loopGuard.recordDisconnect(at: TimeInterval(i), historyIndex: 0)
        }
        #expect(loopGuard.isLooping(at: 5))
        loopGuard.reset()
        #expect(!loopGuard.isLooping(at: 5))
    }
}
