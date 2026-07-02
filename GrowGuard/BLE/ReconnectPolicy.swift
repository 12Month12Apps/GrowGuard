//
//  ReconnectPolicy.swift
//  GrowGuard
//
//  Reine, testbare Bausteine für die Reconnect-Zuverlässigkeit:
//
//  - DisconnectReason: klassifiziert, warum eine Verbindung endete
//  - ReconnectPolicy: reason-abhängige Backoff-Entscheidung (ersetzt die
//    früher dreifach duplizierten Retry-Blöcke im ConnectionPoolManager)
//  - DisconnectLoopGuard: erkennt Reconnect-Schleifen ohne Sync-Fortschritt
//

import Foundation
import CoreBluetooth

// MARK: - DisconnectReason

/// Warum eine Verbindung endete — Grundlage für reason-abhängige Delays
enum DisconnectReason: Equatable {
    /// Sensor hat sauber getrennt (z.B. FlowerCare Idle-Timeout), error == nil
    case clean
    /// CBError.peripheralDisconnected (Code 7)
    case peripheralDisconnected
    /// CBError.connectionTimeout (Code 6)
    case connectionTimeout
    /// didFailToConnect vom Central
    case failedToConnect
    /// Unser eigener Verbindungs-Watchdog (10s ohne didConnect)
    case appTimeout
    /// Bluetooth ist aus oder nicht verfügbar
    case bluetoothUnavailable
    /// Anderer/unbekannter Fehler
    case unknown

    init(error: Error?) {
        guard let error = error else {
            self = .clean
            return
        }
        let nsError = error as NSError
        guard nsError.domain == CBErrorDomain else {
            self = .unknown
            return
        }
        switch CBError.Code(rawValue: nsError.code) {
        case .peripheralDisconnected:
            self = .peripheralDisconnected
        case .connectionTimeout:
            self = .connectionTimeout
        default:
            self = .unknown
        }
    }
}

// MARK: - ReconnectPolicy

/// Backoff-Entscheidung pro fehlgeschlagenem Verbindungsversuch.
/// `attempt` zählt die bisherigen Fehlschläge (1 = erster Fehlschlag).
struct ReconnectPolicy {

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case giveUp
        case waitForBluetooth
    }

    let maxAttempts: Int

    init(maxAttempts: Int = 3) {
        self.maxAttempts = maxAttempts
    }

    func decision(attempt: Int, reason: DisconnectReason) -> Decision {
        if reason == .bluetoothUnavailable {
            return .waitForBluetooth
        }
        guard attempt < maxAttempts else {
            return .giveUp
        }
        return .retry(after: delay(attempt: attempt, reason: reason))
    }

    /// Delay vor einem Auto-Reconnect nach unerwartetem Disconnect
    /// (z.B. mitten im History-Sync)
    func reconnectDelay(reason: DisconnectReason) -> TimeInterval {
        delay(attempt: 1, reason: reason)
    }

    private func delay(attempt: Int, reason: DisconnectReason) -> TimeInterval {
        let schedule: [TimeInterval]
        switch reason {
        case .clean, .peripheralDisconnected:
            // Sensor-seitige Disconnects: schnell wieder ran, der Sensor
            // ist erreichbar
            schedule = [1, 2, 4]
        case .connectionTimeout, .failedToConnect, .unknown, .bluetoothUnavailable:
            // Verbindungsaufbau scheitert: dem Funkumfeld mehr Luft geben
            schedule = [2, 4, 8]
        case .appTimeout:
            // Watchdog-Timeouts: bisheriges Verhalten (1s, 2s, 3s)
            schedule = [1, 2, 3]
        }
        let index = min(max(attempt - 1, 0), schedule.count - 1)
        return schedule[index]
    }
}

// MARK: - DisconnectLoopGuard

/// Erkennt Disconnect-Schleifen: viele Disconnects in kurzer Zeit OHNE
/// Fortschritt im History-Sync. Der Fortschritts-Delta ist das
/// Unterscheidungsmerkmal — 5 Drops, während der Index um hunderte Einträge
/// wächst, sind ein flaky Link, der trotzdem vorankommt; 5 Drops mit
/// eingefrorenem Index sind eine Schleife, die gestoppt werden muss.
struct DisconnectLoopGuard {

    let maxReconnectsWithoutProgress: Int
    let window: TimeInterval

    private var stalledDisconnectTimes: [TimeInterval] = []
    private var lastHistoryIndex = 0

    init(maxReconnectsWithoutProgress: Int = 5, window: TimeInterval = 120) {
        self.maxReconnectsWithoutProgress = maxReconnectsWithoutProgress
        self.window = window
    }

    /// Registriert einen Disconnect mit dem aktuellen History-Index
    mutating func recordDisconnect(at now: TimeInterval, historyIndex: Int) {
        let progressed = historyIndex > lastHistoryIndex
        lastHistoryIndex = historyIndex
        if progressed {
            // Fortschritt seit dem letzten Drop → Streak zurücksetzen,
            // der Sync kommt voran
            stalledDisconnectTimes.removeAll()
        } else {
            stalledDisconnectTimes.append(now)
            stalledDisconnectTimes.removeAll { now - $0 > window }
        }
    }

    /// true sobald zu viele Disconnects ohne Fortschritt im Fenster liegen
    func isLooping(at now: TimeInterval) -> Bool {
        stalledDisconnectTimes.filter { now - $0 <= window }.count >= maxReconnectsWithoutProgress
    }

    mutating func reset() {
        stalledDisconnectTimes.removeAll()
        lastHistoryIndex = 0
    }
}
