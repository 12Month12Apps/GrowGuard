//
//  FakeBLETransport.swift
//  GrowGuardTests
//
//  Test doubles for the BLE transport seam: a manually advanced scheduler,
//  a scriptable fake FlowerCare sensor implementing the real GATT protocol,
//  and a fake central. Together they make connection/auth/history logic
//  fully deterministic on the simulator.
//

import Foundation
import CoreBluetooth
@testable import GrowGuard

// MARK: - TestScheduler

/// Scheduler with virtual time. `advance(by:)` runs all work that becomes
/// due, including work scheduled by the running work itself (nested timer
/// chains), in fire-time order.
final class TestScheduler: BLEScheduler {

    private final class Item: BLEScheduledTask {
        var fireTime: TimeInterval
        let interval: TimeInterval?
        let work: () -> Void
        var isCancelled = false

        init(fireTime: TimeInterval, interval: TimeInterval?, work: @escaping () -> Void) {
            self.fireTime = fireTime
            self.interval = interval
            self.work = work
        }

        func cancel() { isCancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []

    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask {
        let item = Item(fireTime: now + max(0, seconds), interval: nil, work: work)
        items.append(item)
        return item
    }

    @discardableResult
    func scheduleRepeating(every seconds: TimeInterval, _ work: @escaping () -> Void) -> BLEScheduledTask {
        let item = Item(fireTime: now + max(0.001, seconds), interval: max(0.001, seconds), work: work)
        items.append(item)
        return item
    }

    /// Advances virtual time, firing everything that becomes due on the way.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items
            .filter({ !$0.isCancelled && $0.fireTime <= target })
            .min(by: { $0.fireTime < $1.fireTime }) {
            now = max(now, next.fireTime)
            if let interval = next.interval {
                next.fireTime = now + interval
            } else {
                items.removeAll { $0 === next }
            }
            next.work()
        }
        now = target
        items.removeAll { $0.isCancelled }
    }
}

// MARK: - FakeFlowerCarePeripheral

/// Scriptable in-memory FlowerCare sensor speaking the real GATT protocol:
/// auth challenge (0x90CA85DE), live mode (0xA01F), history mode (0xA00000),
/// entry count (0x3C), entry fetch (0xA1 + index LE), device time.
/// Responses are delivered via the scheduler after `responseDelay` so the
/// asynchronous nature of CoreBluetooth is preserved deterministically.
final class FakeFlowerCarePeripheral: BLEPeripheralLink {

    let identifier: UUID
    var name: String? = "Flower care"
    var state: CBPeripheralState = .disconnected
    weak var linkDelegate: BLEPeripheralLinkDelegate?

    private let scheduler: TestScheduler
    private let responseDelay: TimeInterval = 0.01

    // MARK: Device contents (script these per test)

    var historyEntries: [Data] = []
    /// Overrides the reported entry count; default = historyEntries.count
    var reportedEntryCount: Int?
    var uptimeSeconds: UInt32 = 100_000
    var liveDataFrame: Data = FlowerCareFrames.liveRecorded
    var hasAuthCharacteristic = false
    /// false = never answer the auth challenge (forces the 4s timeout path)
    var respondsToAuth = true
    /// true = never answer the history metadata read (forces the 10s timeout path)
    var suppressMetadataResponse = false
    /// Indices answered with a garbage frame that fails decoding
    var corruptEntryIndices: Set<Int> = []
    /// Indices that never get a response (sensor goes silent mid-sync)
    var silentEntryIndices: Set<Int> = []

    // MARK: Introspection

    private(set) var writeLog: [(characteristic: CBUUID, data: Data)] = []
    private(set) var servedEntryIndices: [Int] = []

    private enum PendingHistoryRead {
        case none, metadata, entry(Int)
    }
    private var pendingHistoryRead: PendingHistoryRead = .none

    /// true after a 0xA01F mode change; the realtime characteristic only
    /// returns a fresh frame in live mode
    private(set) var liveModeActive = false

    init(identifier: UUID = UUID(), scheduler: TestScheduler) {
        self.identifier = identifier
        self.scheduler = scheduler
    }

    private func respond(characteristic: CBUUID, value: Data) {
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didUpdateValueFor: characteristic, value: value, error: nil)
        }
    }

    // MARK: BLEPeripheralLink

    func discoverServices() {
        guard state == .connected else { return }
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didDiscoverServices: [dataServiceUUID, historyServiceUUID], error: nil)
        }
    }

    func discoverCharacteristics(forService serviceUUID: CBUUID) {
        guard state == .connected else { return }
        let characteristics: [CBUUID]
        switch serviceUUID {
        case dataServiceUUID:
            var chars = [deviceModeChangeCharacteristicUUID, realTimeSensorValuesCharacteristicUUID, firmwareVersionCharacteristicUUID]
            if hasAuthCharacteristic {
                chars.append(authenticationCharacteristicUUID)
            }
            characteristics = chars
        case historyServiceUUID:
            characteristics = [historyControlCharacteristicUUID, historicalSensorValuesCharacteristicUUID, deviceTimeCharacteristicUUID]
        default:
            characteristics = []
        }
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didDiscoverCharacteristics: characteristics, forService: serviceUUID, error: nil)
        }
    }

    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType) {
        guard state == .connected else { return }
        writeLog.append((characteristicUUID, data))

        switch characteristicUUID {
        case historyControlCharacteristicUUID:
            if data == Data([0xa0, 0x00, 0x00]) {
                // History mode activated
            } else if data == Data([0x3c]) {
                pendingHistoryRead = .metadata
            } else if data.count == 3 && data[0] == 0xa1 {
                let index = Int(data[1]) | (Int(data[2]) << 8)
                pendingHistoryRead = .entry(index)
            }

        case deviceModeChangeCharacteristicUUID:
            if data == Data([0xA0, 0x1F]) {
                // Real sensors switch to live mode; the fresh value must be
                // READ from the realtime characteristic afterwards (miflora
                // protocol) — handled in readValue below
                liveModeActive = true
            }

        case authenticationCharacteristicUUID:
            if data == Data([0x90, 0xCA, 0x85, 0xDE]) {
                // Auth challenge
                if respondsToAuth {
                    respond(characteristic: authenticationCharacteristicUUID,
                            value: Data([0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]))
                }
            } else if respondsToAuth {
                // Final key -> ack completes authentication
                respond(characteristic: authenticationCharacteristicUUID, value: Data([0x00]))
            }

        default:
            break
        }

        // .withResponse writes get a write confirmation
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didWriteValueFor: characteristicUUID, error: nil)
        }
    }

    func readValue(forCharacteristic characteristicUUID: CBUUID) {
        guard state == .connected else { return }

        switch characteristicUUID {
        case deviceTimeCharacteristicUUID:
            var uptime = Data()
            withUnsafeBytes(of: uptimeSeconds.littleEndian) { uptime.append(contentsOf: $0) }
            respond(characteristic: deviceTimeCharacteristicUUID, value: uptime)

        case historicalSensorValuesCharacteristicUUID:
            switch pendingHistoryRead {
            case .metadata:
                guard !suppressMetadataResponse else { return }
                let count = reportedEntryCount ?? historyEntries.count
                respond(characteristic: historicalSensorValuesCharacteristicUUID,
                        value: FlowerCareFrames.historyMetadata(entryCount: UInt16(count)))
            case .entry(let index):
                servedEntryIndices.append(index)
                if silentEntryIndices.contains(index) {
                    // Sensor goes silent — no response at all
                } else if corruptEntryIndices.contains(index) {
                    // Garbage frame: timestamp 0xFFFFFFFF > uptime -> decode fails
                    respond(characteristic: historicalSensorValuesCharacteristicUUID,
                            value: Data(repeating: 0xFF, count: 14))
                } else if index < historyEntries.count {
                    respond(characteristic: historicalSensorValuesCharacteristicUUID,
                            value: historyEntries[index])
                }
            case .none:
                break
            }

        case realTimeSensorValuesCharacteristicUUID:
            guard liveModeActive else { return }
            respond(characteristic: realTimeSensorValuesCharacteristicUUID, value: liveDataFrame)

        case firmwareVersionCharacteristicUUID:
            respond(characteristic: firmwareVersionCharacteristicUUID, value: FlowerCareFrames.firmwareAndBattery)

        default:
            break
        }
    }

    func readRSSI() {
        scheduler.schedule(after: responseDelay) { [weak self] in
            guard let self, self.state == .connected else { return }
            self.linkDelegate?.peripheralLink(self, didReadRSSI: -55, error: nil)
        }
    }
}

// MARK: - FakeCentral

/// Fake BLECentral: vends scripted peripherals, connects synchronously,
/// and lets tests flip Bluetooth state or trigger discovery.
final class FakeCentral: BLECentral {

    var state: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralDelegate?

    /// Peripherals the central knows about
    var knownPeripherals: [UUID: FakeFlowerCarePeripheral] = [:]
    /// false = retrievePeripherals returns nothing (forces the scan path)
    var peripheralsAreInRetrieveCache = true
    /// false = connect() does nothing (forces the timeout/retry path)
    var connectSucceeds = true

    private(set) var isScanning = false
    private(set) var connectRequests: [UUID] = []

    func register(_ peripheral: FakeFlowerCarePeripheral) {
        knownPeripherals[peripheral.identifier] = peripheral
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        guard peripheralsAreInRetrieveCache else { return [] }
        return identifiers.compactMap { knownPeripherals[$0] }
    }

    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        connectRequests.append(peripheral.identifier)
        guard connectSucceeds, let fake = knownPeripherals[peripheral.identifier] else { return }
        fake.state = .connected
        centralDelegate?.central(self, didConnect: fake)
    }

    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        guard let fake = knownPeripherals[peripheral.identifier] else { return }
        let wasConnected = fake.state == .connected
        fake.state = .disconnected
        if wasConnected {
            centralDelegate?.central(self, didDisconnect: fake, error: nil)
        }
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        isScanning = true
    }

    func stopScan() {
        isScanning = false
    }

    // MARK: Test triggers

    /// Simulates the central reporting a discovery for a registered peripheral
    func simulateDiscovery(of identifier: UUID) {
        guard let fake = knownPeripherals[identifier] else { return }
        centralDelegate?.central(self, didDiscover: fake, advertisementData: [:], rssi: NSNumber(value: -55))
    }

    /// Simulates an unexpected disconnect of a connected peripheral
    func simulateDisconnect(of identifier: UUID, error: Error? = nil) {
        guard let fake = knownPeripherals[identifier] else { return }
        fake.state = .disconnected
        centralDelegate?.central(self, didDisconnect: fake, error: error)
    }

    /// Simulates a Bluetooth state change
    func simulateStateChange(to newState: CBManagerState) {
        state = newState
        centralDelegate?.central(self, didUpdateState: newState)
    }
}
