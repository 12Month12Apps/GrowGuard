//
//  BLEBridgeConfig.swift
//  GrowGuard
//
//  Debug-only: reads GROWGUARD_BLE_BRIDGE=host:port once at launch. When set,
//  the BLE stack and the Add Device flow route over a localhost socket to
//  FlowerCareSim instead of CoreBluetooth (single-machine testing without a
//  radio). When unset — always, in release — nothing changes.
//

#if DEBUG
import Foundation

enum BLEBridgeConfig {
    /// Parsed `(host, port)` from the environment, or nil when the bridge is off.
    static let endpoint: (host: String, port: UInt16)? = {
        guard let raw = ProcessInfo.processInfo.environment["GROWGUARD_BLE_BRIDGE"] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }()

    static var isEnabled: Bool { endpoint != nil }
}
#endif
