//
//  ReplayBLETransport.swift
//  GrowGuardTests
//
//  Plays a BLESessionRecording back against the code under test.
//
//  The recording is treated as an ordered script: every outbound event the
//  app produces (connect, write, read, discover…) is matched against the
//  next expected outbound event — THAT is the regression check. On a match,
//  the inbound events that followed it in the recording (responses,
//  disconnects…) are delivered through the TestScheduler at their recorded
//  relative delays, so a multi-minute real-world session replays in
//  milliseconds of virtual time.
//
//  RSSI traffic (readRSSI/rssiRead) is timing noise from periodic timers
//  and is excluded from matching; readRSSI calls get a canned response.
//

import Foundation
import CoreBluetooth
@testable import GrowGuard

// MARK: - ReplaySession

final class ReplaySession {

    struct Mismatch: CustomStringConvertible {
        let scriptIndex: Int
        let expected: String
        let actual: String
        var description: String { "script[\(scriptIndex)]: expected \(expected), app did \(actual)" }
    }

    let recording: BLESessionRecording
    private let scheduler: TestScheduler
    /// Script without RSSI noise
    private let events: [BLESessionEvent]
    private var cursor = 0

    private(set) var mismatches: [Mismatch] = []
    private let maxMismatches = 10

    weak var central: ReplayCentral?
    weak var peripheral: ReplayPeripheral?

    init(recording: BLESessionRecording, scheduler: TestScheduler) {
        self.recording = recording
        self.scheduler = scheduler
        self.events = recording.events.filter { $0.type != .readRSSI && $0.type != .rssiRead }
    }

    var isScriptExhausted: Bool { cursor >= events.count }
    /// (verarbeitete Ereignisse, Script-Länge) — für Stall-Diagnose
    var scriptProgress: (processed: Int, total: Int) { (cursor, events.count) }

    /// Delivers inbound events that precede the first outbound event
    /// (e.g. a leading bluetoothState change)
    func start() {
        scheduleInboundRun(after: 0)
    }

    // MARK: Outbound matching

    func handleOutbound(_ type: BLESessionEvent.EventType,
                        char: CBUUID? = nil,
                        service: CBUUID? = nil,
                        data: Data? = nil) {
        guard mismatches.count < maxMismatches else { return }

        let actual = describe(type, char: char, service: service, data: data)
        guard cursor < events.count else {
            record(expected: "(script exhausted)", actual: actual)
            return
        }

        let expected = events[cursor]
        guard expected.type.isOutbound else {
            record(expected: "inbound \(expected.type.rawValue) (script out of sync)", actual: actual)
            return
        }

        if matches(expected, type: type, char: char, service: service, data: data) {
            let baseTime = expected.t
            cursor += 1
            scheduleInboundRun(after: baseTime)
        } else {
            record(expected: describe(expected), actual: actual)
        }
    }

    /// Canned response for RSSI reads (excluded from strict matching)
    func respondToRSSIRead() {
        scheduler.schedule(after: 0.001) { [weak self] in
            guard let self = self, let peripheral = self.peripheral, peripheral.state == .connected else { return }
            peripheral.linkDelegate?.peripheralLink(peripheral, didReadRSSI: -55, error: nil)
        }
    }

    // MARK: Private

    private func record(expected: String, actual: String) {
        mismatches.append(Mismatch(scriptIndex: cursor, expected: expected, actual: actual))
    }

    private func matches(_ expected: BLESessionEvent,
                         type: BLESessionEvent.EventType,
                         char: CBUUID?,
                         service: CBUUID?,
                         data: Data?) -> Bool {
        guard expected.type == type else { return false }
        switch type {
        case .write:
            return expected.char == char?.uuidString && expected.data == data?.hexEncodedString
        case .read:
            return expected.char == char?.uuidString
        case .discoverCharacteristics:
            return expected.service == service?.uuidString
        default:
            return true
        }
    }

    private func describe(_ event: BLESessionEvent) -> String {
        describe(event.type,
                 char: event.char.map { CBUUID(string: $0) },
                 service: event.service.map { CBUUID(string: $0) },
                 data: event.data.flatMap { Data(hexEncoded: $0) })
    }

    private func describe(_ type: BLESessionEvent.EventType, char: CBUUID?, service: CBUUID?, data: Data?) -> String {
        var parts = [type.rawValue]
        if let char = char { parts.append("char=\(char.uuidString)") }
        if let service = service { parts.append("service=\(service.uuidString)") }
        if let data = data { parts.append("data=\(data.hexEncodedString)") }
        return parts.joined(separator: " ")
    }

    /// Schedules delivery of all inbound events at the cursor, advancing it
    /// to the next outbound event. Delays are relative to the matched
    /// outbound event's recorded time, clamped to stay strictly positive.
    private func scheduleInboundRun(after baseTime: TimeInterval) {
        while cursor < events.count && !events[cursor].type.isOutbound {
            let event = events[cursor]
            cursor += 1
            let delay = max(0.001, event.t - baseTime)
            scheduler.schedule(after: delay) { [weak self] in
                self?.deliver(event)
            }
        }
    }

    private func deliver(_ event: BLESessionEvent) {
        guard let peripheral = peripheral, let central = central else { return }

        switch event.type {
        case .connected:
            peripheral.state = .connected
            central.centralDelegate?.central(central, didConnect: peripheral)

        case .disconnected:
            peripheral.state = .disconnected
            central.centralDelegate?.central(central, didDisconnect: peripheral, error: reconstructError(event))

        case .failedToConnect:
            peripheral.state = .disconnected
            central.centralDelegate?.central(central, didFailToConnect: peripheral, error: reconstructError(event))

        case .bluetoothState:
            if let raw = event.state, let state = CBManagerState(rawValue: raw) {
                central.state = state
                central.centralDelegate?.central(central, didUpdateState: state)
            }

        case .servicesDiscovered:
            peripheral.linkDelegate?.peripheralLink(
                peripheral,
                didDiscoverServices: (event.services ?? []).map { CBUUID(string: $0) },
                error: reconstructError(event))

        case .characteristicsDiscovered:
            guard let service = event.service else { return }
            peripheral.linkDelegate?.peripheralLink(
                peripheral,
                didDiscoverCharacteristics: (event.chars ?? []).map { CBUUID(string: $0) },
                forService: CBUUID(string: service),
                error: reconstructError(event))

        case .valueUpdated:
            guard let char = event.char else { return }
            peripheral.linkDelegate?.peripheralLink(
                peripheral,
                didUpdateValueFor: CBUUID(string: char),
                value: event.data.flatMap { Data(hexEncoded: $0) },
                error: reconstructError(event))

        case .writeConfirmed:
            guard let char = event.char else { return }
            peripheral.linkDelegate?.peripheralLink(
                peripheral,
                didWriteValueFor: CBUUID(string: char),
                error: reconstructError(event))

        default:
            break
        }
    }

    private func reconstructError(_ event: BLESessionEvent) -> Error? {
        guard let domain = event.errorDomain, let code = event.errorCode else { return nil }
        var userInfo: [String: Any] = [:]
        if let message = event.errorMessage {
            userInfo[NSLocalizedDescriptionKey] = message
        }
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
}

// MARK: - ReplayPeripheral

final class ReplayPeripheral: BLEPeripheralLink {

    let identifier: UUID
    var name: String?
    var state: CBPeripheralState = .disconnected
    weak var linkDelegate: BLEPeripheralLinkDelegate?

    private let session: ReplaySession

    init(session: ReplaySession) {
        self.session = session
        self.identifier = UUID(uuidString: session.recording.deviceUUID) ?? UUID()
        self.name = session.recording.deviceName
        session.peripheral = self
    }

    func discoverServices() {
        session.handleOutbound(.discoverServices)
    }

    func discoverCharacteristics(forService serviceUUID: CBUUID) {
        session.handleOutbound(.discoverCharacteristics, service: serviceUUID)
    }

    func readValue(forCharacteristic characteristicUUID: CBUUID) {
        session.handleOutbound(.read, char: characteristicUUID)
    }

    func writeValue(_ data: Data, forCharacteristic characteristicUUID: CBUUID, type: CBCharacteristicWriteType) {
        session.handleOutbound(.write, char: characteristicUUID, data: data)
    }

    func readRSSI() {
        session.respondToRSSIRead()
    }
}

// MARK: - ReplayCentral

final class ReplayCentral: BLECentral {

    var state: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralDelegate?

    let peripheral: ReplayPeripheral
    private let session: ReplaySession
    private(set) var isScanning = false

    init(session: ReplaySession) {
        self.session = session
        self.peripheral = ReplayPeripheral(session: session)
        session.central = self
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        identifiers.contains(peripheral.identifier) ? [peripheral] : []
    }

    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        session.handleOutbound(.connectRequested)
    }

    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        session.handleOutbound(.cancelConnect)
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        isScanning = true
    }

    func stopScan() {
        isScanning = false
    }
}
