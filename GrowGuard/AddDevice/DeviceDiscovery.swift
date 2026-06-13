//
//  DeviceDiscovery.swift
//  GrowGuard
//
//  Seam for the Add Device flow, decoupled from CoreBluetooth so onboarding can
//  be driven by the real scanner or — in DEBUG — the localhost bridge to
//  FlowerCareSim. Mirrors the BLETransport seam philosophy: the view layer sees
//  a plain `DiscoveredDevice`, never a CBPeripheral.
//

import Foundation
import CoreBluetooth

/// A device seen during onboarding.
struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String?
}

/// Scans for addable sensors and reports them as `DiscoveredDevice`s.
protocol DeviceDiscovery: AnyObject {
    var onState: ((CBManagerState) -> Void)? { get set }
    var onFound: ((DiscoveredDevice) -> Void)? { get set }
    func start()
    func stop()
}

/// Production scanner: wraps the CBCentralManager-based `AddDeviceBLE`.
final class CoreBluetoothDeviceDiscovery: DeviceDiscovery {
    var onState: ((CBManagerState) -> Void)?
    var onFound: ((DiscoveredDevice) -> Void)?
    private var ble: AddDeviceBLE?

    func start() {
        ble = AddDeviceBLE(
            foundDevice: { [weak self] peripheral in
                self?.onFound?(DiscoveredDevice(id: peripheral.identifier, name: peripheral.name))
            },
            stateChanged: { [weak self] state in
                self?.onState?(state)
            }
        )
        ble?.startScanning()
    }

    func stop() {
        ble?.stopScanning()
        ble = nil
    }
}
