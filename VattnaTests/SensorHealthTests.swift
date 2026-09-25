//
//  SensorHealthTests.swift
//  VattnaTests
//
//  Pure verdict logic (spec 2026-09-14-sensor-health-design.md).
//

import Testing
import Foundation
@testable import Vattna

struct SensorHealthTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    private func sensor(uuid: String = "A",
                        battery: Int16 = 80,
                        batteryUpdatedAt: Date? = Date(timeIntervalSince1970: 1_799_990_000),
                        silentFor: TimeInterval = 0,
                        attempts: Int16 = 0,
                        location: String? = nil,
                        isSensor: Bool = true) -> FlowerDeviceDTO {
        FlowerDeviceDTO(
            name: uuid,
            uuid: uuid,
            battery: battery,
            batteryUpdatedAt: batteryUpdatedAt,
            isSensor: isSensor,
            lastUpdate: now.addingTimeInterval(-silentFor),
            failedContactAttempts: attempts,
            location: location
        )
    }

    private func evaluate(_ device: FlowerDeviceDTO, peers: [FlowerDeviceDTO] = []) -> SensorHealth {
        SensorHealth.evaluate(device, peers: peers, now: now)
    }

    // MARK: Gates

    @Test("47 h silent with many failures is not unreachable (time gate)")
    func timeGate() {
        #expect(evaluate(sensor(silentFor: 47 * hour, attempts: 10)) == .ok)
    }

    @Test("5 days silent with 2 failures is not unreachable (attempt gate)")
    func attemptGate() {
        #expect(evaluate(sensor(silentFor: 5 * 24 * hour, attempts: 2)) == .ok)
    }

    @Test("48 h and 3 failures → unreachable with last known battery")
    func unreachable() {
        let device = sensor(battery: 25, silentFor: 48 * hour, attempts: 3)
        #expect(evaluate(device) == .unreachable(since: device.lastReading, lastKnownBattery: 25, confirmedByPeer: false))
    }

    @Test("Unreachable without any battery read carries nil")
    func unreachableWithoutBattery() {
        let device = sensor(battery: 0, batteryUpdatedAt: nil, silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device) == .unreachable(since: device.lastReading, lastKnownBattery: nil, confirmedByPeer: false))
    }

    @Test("Unreachable wins over low battery")
    func unreachableBeatsLowBattery() {
        #expect(evaluate(sensor(battery: 10, silentFor: 3 * 24 * hour, attempts: 3)).isUnreachable)
    }

    @Test("lastReading counts the newest sample, not only lastUpdate")
    func usesNewestSample() {
        var device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        device = FlowerDeviceDTO(
            name: device.name, uuid: device.uuid, battery: device.battery,
            batteryUpdatedAt: device.batteryUpdatedAt, lastUpdate: device.lastUpdate,
            failedContactAttempts: device.failedContactAttempts,
            sensorData: [SensorDataDTO(temperature: 20, brightness: 1, moisture: 1, conductivity: 1,
                                       date: now.addingTimeInterval(-hour), deviceUUID: device.uuid)]
        )
        #expect(evaluate(device) == .ok)
    }

    // MARK: Peer witness

    @Test("A fresh peer at the same location confirms")
    func peerConfirms() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3, location: "Balcony")
        let peer = sensor(uuid: "B", silentFor: hour, location: "Balcony")
        #expect(evaluate(device, peers: [peer]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: true))
    }

    @Test("A fresh peer at another location does not confirm")
    func peerOtherLocation() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3, location: "Balcony")
        let peer = sensor(uuid: "B", silentFor: hour, location: "Living room")
        #expect(evaluate(device, peers: [peer]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("nil location matches only nil")
    func nilLocationGroup() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: hour)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: true))
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: hour, location: "Balcony")]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("A peer that is itself silent for 3 days is no witness")
    func silentPeer() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: 3 * 24 * hour)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("A non-sensor peer with a fresh lastUpdate is ignored")
    func nonSensorPeer() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [sensor(uuid: "B", silentFor: 0, isSensor: false)]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    @Test("The device itself in the peer list is not its own witness")
    func selfIsNoWitness() {
        let device = sensor(silentFor: 3 * 24 * hour, attempts: 3)
        #expect(evaluate(device, peers: [device]) == .unreachable(since: device.lastReading, lastKnownBattery: 80, confirmedByPeer: false))
    }

    // MARK: Battery

    @Test("Battery boundaries: 30 low, 31 ok, 15 critical, 16 low")
    func batteryBoundaries() {
        #expect(evaluate(sensor(battery: 30)) == .batteryLow(percent: 30))
        #expect(evaluate(sensor(battery: 31)) == .ok)
        #expect(evaluate(sensor(battery: 15)) == .batteryCritical(percent: 15))
        #expect(evaluate(sensor(battery: 16)) == .batteryLow(percent: 16))
    }

    @Test("Never read → unknown even when the value is 0")
    func neverRead() {
        #expect(evaluate(sensor(battery: 0, batteryUpdatedAt: nil)) == .batteryUnknown)
    }

    @Test("Legacy device: value without timestamp is evaluated, read-at falls back to lastUpdate")
    func legacyDevice() {
        let device = sensor(battery: 25, batteryUpdatedAt: nil)
        #expect(evaluate(device) == .batteryLow(percent: 25))
        #expect(device.batteryReadAt == device.lastUpdate)
    }

    @Test("Non-sensor devices are always ok")
    func nonSensor() {
        #expect(evaluate(sensor(battery: 0, batteryUpdatedAt: nil, silentFor: 30 * 24 * hour, attempts: 9, isSensor: false)) == .ok)
    }

    @Test("isLowBattery covers low and critical, daysSilent floors")
    func helpers() {
        #expect(SensorHealth.batteryLow(percent: 20).isLowBattery)
        #expect(SensorHealth.batteryCritical(percent: 5).isLowBattery)
        #expect(!SensorHealth.ok.isLowBattery)
        #expect(SensorHealth.daysSilent(since: now.addingTimeInterval(-2.9 * 24 * hour), now: now) == 2)
    }
}
