//
//  SensorHealth.swift
//  Vattna
//
//  Pure verdict for one sensor (spec docs/superpowers/specs/2026-09-14-sensor-health-design.md).
//  No BLE, no Core Data: a DTO plus its peers go in, a state comes out.
//

import Foundation

enum SensorHealth: Equatable {
    case ok
    /// Battery never read from this sensor
    case batteryUnknown
    case batteryLow(percent: Int)
    case batteryCritical(percent: Int)
    /// No reading for `unreachableAfter` AND `unreachableAttempts` failed
    /// contacts. `confirmedByPeer` is true when another sensor at the same
    /// location delivered a reading inside the window — the phone was in
    /// range, this sensor is dead. Otherwise it may just be out of range.
    case unreachable(since: Date, lastKnownBattery: Int?, confirmedByPeer: Bool)

    // MARK: - Thresholds (the only place they live)

    static let unreachableAfter: TimeInterval = 48 * 60 * 60
    static let unreachableAttempts: Int16 = 3
    /// Percentages are an assumption: the reported failure was at 25 % and
    /// FlowerCare units with weak cells stop responding in the 20–30 % band.
    static let lowBattery = 30
    static let criticalBattery = 15
    /// Views caption the battery with its age beyond this
    static let staleBatteryAfter: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Evaluation

    /// `peers` are the other devices; only sensors at the same location act
    /// as witnesses. `nil` location matches only `nil`.
    static func evaluate(_ device: FlowerDeviceDTO, peers: [FlowerDeviceDTO], now: Date) -> SensorHealth {
        guard device.isSensor else { return .ok }

        let silentFor = now.timeIntervalSince(device.lastReading)
        if silentFor >= unreachableAfter && device.failedContactAttempts >= unreachableAttempts {
            let witnessed = peers.contains { peer in
                peer.isSensor
                    && peer.uuid != device.uuid
                    && peer.location == device.location
                    && now.timeIntervalSince(peer.lastReading) < unreachableAfter
            }
            let lastKnown = device.batteryReadAt == nil ? nil : Int(device.battery)
            return .unreachable(since: device.lastReading, lastKnownBattery: lastKnown, confirmedByPeer: witnessed)
        }

        guard device.batteryReadAt != nil else { return .batteryUnknown }
        let percent = Int(device.battery)
        if percent <= criticalBattery { return .batteryCritical(percent: percent) }
        if percent <= lowBattery { return .batteryLow(percent: percent) }
        return .ok
    }

    // MARK: - Helpers

    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    var isLowBattery: Bool {
        switch self {
        case .batteryLow, .batteryCritical: return true
        default: return false
        }
    }

    /// Whole days since `since`, floored. Used in copy ("silent for 3 days").
    static func daysSilent(since: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(since) / (24 * 60 * 60)))
    }
}
