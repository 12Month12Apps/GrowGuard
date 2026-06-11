//
//  BLETransport.swift
//  GrowGuard
//
//  Protocol seam over CoreBluetooth (BLE-Testing-Strategy.md, Phase 3).
//
//  ConnectionPoolManager and DeviceConnection talk to these protocols
//  instead of CBCentralManager/CBPeripheral directly. Production uses the
//  CoreBluetooth-backed implementations (CoreBluetoothTransport.swift) via
//  default arguments; tests inject fakes and a manually advanced scheduler,
//  which makes connection, authentication, history-resume and retry logic
//  deterministic and simulator-friendly.
//

import Foundation
import CoreBluetooth

// MARK: - Scheduler

/// Handle for cancelling a scheduled piece of work (replaces Timer storage).
protocol BLEScheduledTask {
    func cancel()
}

/// Abstraction over Timer/DispatchQueue delays so tests can advance time
/// manually instead of sleeping.
protocol BLEScheduler {
    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask

    @discardableResult
    func scheduleRepeating(every seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask
}

/// Production scheduler backed by Timer on the main run loop — the same
/// mechanics the BLE classes used before the seam existed.
final class MainRunLoopScheduler: BLEScheduler {

    private final class TimerTask: BLEScheduledTask {
        private weak var timer: Timer?
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer?.invalidate() }
    }

    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in work() }
        return TimerTask(timer)
    }

    @discardableResult
    func scheduleRepeating(every seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in work() }
        return TimerTask(timer)
    }
}

// MARK: - Peripheral link

/// Delegate callbacks for a single peripheral, expressed in UUIDs and raw
/// Data so no CoreBluetooth object graph leaks through the seam.
protocol BLEPeripheralLinkDelegate: AnyObject {
    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverServices serviceUUIDs: [CBUUID], error: Error?)
    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverCharacteristics characteristicUUIDs: [CBUUID], forService serviceUUID: CBUUID, error: Error?)
    func peripheralLink(_ link: BLEPeripheralLink, didUpdateValueFor characteristicUUID: CBUUID, value: Data?, error: Error?)
    func peripheralLink(_ link: BLEPeripheralLink, didWriteValueFor characteristicUUID: CBUUID, error: Error?)
    func peripheralLink(_ link: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?)
}

/// One BLE peripheral as seen by DeviceConnection.
protocol BLEPeripheralLink: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var state: CBPeripheralState { get }
    var linkDelegate: BLEPeripheralLinkDelegate? { get set }

    func discoverServices()
    func discoverCharacteristics(forService serviceUUID: CBUUID)
    func readValue(forCharacteristic characteristicUUID: CBUUID)
    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType)
    func readRSSI()
}

// MARK: - Central

/// Delegate callbacks of the central, mirroring CBCentralManagerDelegate
/// but vending BLEPeripheralLink instances.
protocol BLECentralDelegate: AnyObject {
    func central(_ central: BLECentral, didUpdateState state: CBManagerState)
    func central(_ central: BLECentral, didDiscover peripheral: BLEPeripheralLink, advertisementData: [String: Any], rssi: NSNumber)
    func central(_ central: BLECentral, didConnect peripheral: BLEPeripheralLink)
    func central(_ central: BLECentral, didDisconnect peripheral: BLEPeripheralLink, error: Error?)
    func central(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheralLink, error: Error?)
    func central(_ central: BLECentral, willRestoreState peripherals: [BLEPeripheralLink])
}

/// The central manager as seen by ConnectionPoolManager.
protocol BLECentral: AnyObject {
    var state: CBManagerState { get }
    var centralDelegate: BLECentralDelegate? { get set }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink]
    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?)
    func cancelConnection(_ peripheral: BLEPeripheralLink)
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
}
