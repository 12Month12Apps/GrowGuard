//
//  LiveReadGate.swift
//  GrowGuard
//
//  The details screen shares its pool connection with background wake
//  reads (BackgroundBLEWakeService). Without this gate the screen answered
//  every authentication with its own live request and saved every sample
//  as "Live (User)" — background samples were requested and stored twice.
//

import Foundation

struct LiveReadGate {

    /// How long a claim stays valid. Covers the pool's connect watchdog and
    /// retry backoff; a wake read hours later must not match an old claim.
    static let claimLifetime: TimeInterval = 60

    private enum State: Equatable {
        case idle
        case awaitingAuthentication
        case awaitingSample
    }

    private var state: State = .idle
    private var claimedAt: Date?

    /// The screen started a connect and wants one live sample from it
    mutating func claim(at now: Date) {
        state = .awaitingAuthentication
        claimedAt = now
    }

    /// - Returns: true if the screen should request live data now
    mutating func connectionAuthenticated(at now: Date) -> Bool {
        guard state == .awaitingAuthentication,
              let claimedAt,
              now.timeIntervalSince(claimedAt) <= Self.claimLifetime else {
            return false
        }
        state = .awaitingSample
        return true
    }

    /// - Returns: true if this sample answers the screen's own request
    mutating func sampleReceived() -> Bool {
        guard state == .awaitingSample else { return false }
        state = .idle
        claimedAt = nil
        return true
    }

    /// The link dropped before the answer: re-request after the reconnect
    mutating func connectionLost() {
        if state == .awaitingSample {
            state = .awaitingAuthentication
        }
    }
}
