//
//  SensorDataDecoderTests.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Testing
import Foundation
@testable import GrowGuard

struct SensorDataDecoderTests {

    let decoder = SensorDataDecoder()

    // MARK: - Real-Time Sensor Values

    @Test("Decode real-time sensor values from recorded device frame")
    func decodeRealTimeSensorValuesWithDebugData() {
        let sensorData = decoder.decodeRealTimeSensorValues(data: FlowerCareFrames.liveRecorded, deviceUUID: "1")
        #expect(sensorData != nil)
        #expect(sensorData?.temperature == 23.9)
        #expect(sensorData?.brightness == 185)
        #expect(sensorData?.moisture == 51)
        #expect(sensorData?.conductivity == 1019)
        #expect(sensorData?.device == "1")
    }

    @Test("Decode sub-zero temperature as signed value")
    func decodeRealTimeSensorValuesSubZero() {
        // 0xFFF1 little endian = -15 -> -1.5 °C. The unsigned interpretation
        // would yield 6552.1 °C, which the validation layer clamps to 100 °C
        // and stores as a real reading — frost data must decode correctly.
        let sensorData = decoder.decodeRealTimeSensorValues(data: FlowerCareFrames.liveSubZero, deviceUUID: "1")
        #expect(sensorData?.temperature == -1.5)
    }

    @Test("Real-time decode rejects wrong lengths", arguments: [0, 1, 15, 17, 64])
    func decodeRealTimeSensorValuesInvalidLength(length: Int) {
        let data = Data(repeating: 0xAB, count: length)
        #expect(decoder.decodeRealTimeSensorValues(data: data, deviceUUID: "1") == nil)
    }

    // MARK: - Historical Sensor Data

    private func makeHistoryEntry(timestamp: UInt32,
                                  temperatureX10: Int16,
                                  brightness: UInt32,
                                  moisture: UInt8,
                                  conductivity: UInt16) -> Data {
        FlowerCareFrames.historyEntry(timestamp: timestamp,
                                      temperatureX10: temperatureX10,
                                      brightness: brightness,
                                      moisture: moisture,
                                      conductivity: conductivity)
    }

    @Test("Decode historical entry with sub-zero temperature")
    func decodeHistoricalSensorDataSubZero() {
        decoder.setDeviceBootTime(bootTime: Date().addingTimeInterval(-1000), secondsSinceBoot: 1000)

        let data = makeHistoryEntry(timestamp: 91,
                                    temperatureX10: -83, // -8.3 °C
                                    brightness: 0,
                                    moisture: 40,
                                    conductivity: 200)

        let entry = decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1")
        #expect(entry?.temperature == -8.3)
    }

    @Test("Decode historical entry with known device time")
    func decodeHistoricalSensorData() {
        let secondsSinceBoot: UInt32 = 1000
        decoder.setDeviceBootTime(bootTime: Date().addingTimeInterval(-Double(secondsSinceBoot)),
                                  secondsSinceBoot: secondsSinceBoot)

        let data = makeHistoryEntry(timestamp: 91,
                                    temperatureX10: 284,   // 28.4 °C
                                    brightness: 1200,
                                    moisture: 78,
                                    conductivity: 350)

        let entry = decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1")
        #expect(entry != nil)
        #expect(entry?.timestamp == 91)
        #expect(entry?.temperature == 28.4)
        #expect(entry?.brightness == 1200)
        #expect(entry?.moisture == 78)
        #expect(entry?.conductivity == 350)
        #expect(entry?.deviceUUID == "1")

        // Entry was recorded (1000 - 91) seconds ago
        let expectedDate = Date().addingTimeInterval(-909)
        if let date = entry?.date {
            #expect(abs(date.timeIntervalSince(expectedDate)) < 5)
        }
    }

    @Test("Historical decode fails without prior device time")
    func decodeHistoricalSensorDataWithoutBootTime() {
        let data = makeHistoryEntry(timestamp: 91,
                                    temperatureX10: 284,
                                    brightness: 1200,
                                    moisture: 78,
                                    conductivity: 350)

        // No setDeviceBootTime call -> decoder cannot compute the entry date
        #expect(decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1") == nil)
    }

    @Test("Historical decode rejects timestamp newer than device uptime")
    func decodeHistoricalSensorDataFutureTimestamp() {
        decoder.setDeviceBootTime(bootTime: Date().addingTimeInterval(-100), secondsSinceBoot: 100)

        let data = makeHistoryEntry(timestamp: 500, // > 100 seconds uptime -> invalid
                                    temperatureX10: 284,
                                    brightness: 1200,
                                    moisture: 78,
                                    conductivity: 350)

        #expect(decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1") == nil)
    }

    @Test("Historical decode rejects short data", arguments: [0, 1, 13])
    func decodeHistoricalSensorDataInvalidLength(length: Int) {
        decoder.setDeviceBootTime(bootTime: Date(), secondsSinceBoot: 1000)
        let data = Data(repeating: 0x00, count: length)
        #expect(decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1") == nil)
    }

    // MARK: - History Metadata

    @Test("Decode history metadata entry count")
    func decodeHistoryMetadata() {
        let result = decoder.decodeHistoryMetadata(data: FlowerCareFrames.historyMetadata(entryCount: 200))
        #expect(result?.entryCount == 200)
    }

    @Test("History metadata accepts plausibility upper bound")
    func decodeHistoryMetadataUpperBound() {
        let result = decoder.decodeHistoryMetadata(data: FlowerCareFrames.historyMetadata(entryCount: 10000))
        #expect(result?.entryCount == 10000)
    }

    @Test("History metadata rejects implausible entry count")
    func decodeHistoryMetadataCorruptCount() {
        // 10001 entries -> above plausibility limit
        #expect(decoder.decodeHistoryMetadata(data: FlowerCareFrames.historyMetadata(entryCount: 10001)) == nil)
    }

    @Test("History metadata rejects short data")
    func decodeHistoryMetadataInvalidLength() {
        #expect(decoder.decodeHistoryMetadata(data: Data(repeating: 0x00, count: 15)) == nil)
    }

    // MARK: - Firmware and Battery

    @Test("Decode firmware version and battery level")
    func decodeFirmwareAndBattery() {
        let result = decoder.decodeFirmwareAndBattery(data: FlowerCareFrames.firmwareAndBattery)
        #expect(result?.batteryLevel == 80)
        #expect(result?.firmwareVersion == "3.2.9")
    }

    @Test("Firmware decode rejects wrong lengths", arguments: [0, 6, 8])
    func decodeFirmwareAndBatteryInvalidLength(length: Int) {
        let data = Data(repeating: 0x33, count: length)
        #expect(decoder.decodeFirmwareAndBattery(data: data) == nil)
    }

    // MARK: - Device Name

    @Test("Decode ASCII device name")
    func decodeDeviceName() {
        let data = "Flower care".data(using: .ascii)!
        #expect(decoder.decodeDeviceName(data: data) == "Flower care")
    }

    @Test("Device name decode fails for non-ASCII bytes")
    func decodeDeviceNameInvalid() {
        let data = Data([0xFF, 0xFE, 0xFD])
        #expect(decoder.decodeDeviceName(data: data) == nil)
    }

    // MARK: - Device Time

    @Test("Decode device time as seconds since boot")
    func decodeDeviceTime() {
        #expect(decoder.decodeDeviceTime(data: FlowerCareFrames.deviceTime10000) == 10000)
    }

    @Test("Device time decode rejects wrong lengths", arguments: [0, 3, 5])
    func decodeDeviceTimeInvalidLength(length: Int) {
        let data = Data(repeating: 0x01, count: length)
        #expect(decoder.decodeDeviceTime(data: data) == nil)
    }

    // MARK: - Entry Count

    @Test("Decode entry count little endian")
    func decodeEntryCount() {
        #expect(decoder.decodeEntryCount(data: Data([0x00, 0x05])) == 1280)
        #expect(decoder.decodeEntryCount(data: Data([150, 0])) == 150)
    }

    @Test("Entry count decode rejects wrong lengths", arguments: [0, 1, 3])
    func decodeEntryCountInvalidLength(length: Int) {
        let data = Data(repeating: 0x00, count: length)
        #expect(decoder.decodeEntryCount(data: data) == nil)
    }

    // MARK: - Hex Fixture Helper

    @Test("Hex string helper parses logged frames")
    func hexStringHelper() {
        #expect(Data(hexString: "ef00") == Data([0xEF, 0x00]))
        #expect(Data(hexString: "EF 00 03 B9") == Data([0xEF, 0x00, 0x03, 0xB9]))
        #expect(Data(hexString: "") == Data())
        #expect(Data(hexString: "abc") == nil)   // odd length
        #expect(Data(hexString: "zz00") == nil)  // non-hex characters
    }

    // MARK: - Advertisement Decoders (characterization)
    //
    // These pin the CURRENT behavior of the advertisement decoders. Both
    // formats are best-guess implementations (see SensorDataDecoder comments)
    // that have not been verified against recorded advertisements. If a real
    // capture contradicts them, change the decoder and these expectations
    // together.

    @Test("MiBeacon decode pins current byte layout")
    func decodeMiBeaconAdvertisementCharacterization() {
        // manufacturer ID 0x038F LE | bytes 4..7 brightness | 8..9 temp x10 | 10 moisture | 11..12 conductivity
        let data = Data([
            0x8F, 0x03,             // Xiaomi manufacturer ID
            0x00, 0x00,             // header padding
            0xB8, 0x01, 0x00, 0x00, // brightness 440
            0xEF, 0x00,             // temperature raw 239 -> 23.9 °C
            0x33,                   // moisture 51
            0xFB, 0x03,             // conductivity 1019
            0x00, 0x00, 0x00        // padding to 16 bytes
        ])

        let result = decoder.decodeMiBeaconAdvertisement(data: data, deviceUUID: "1")
        #expect(result?.temperature == 23.9)
        #expect(result?.brightness == 440)
        #expect(result?.moisture == 51)
        #expect(result?.conductivity == 1019)
    }

    @Test("MiBeacon decode rejects foreign manufacturer and short data")
    func decodeMiBeaconAdvertisementRejections() {
        // Wrong manufacturer ID
        var foreign = Data([0x4C, 0x00]) // Apple
        foreign.append(Data(repeating: 0x00, count: 14))
        #expect(decoder.decodeMiBeaconAdvertisement(data: foreign, deviceUUID: "1") == nil)

        // Xiaomi ID but shorter than 12 bytes
        #expect(decoder.decodeMiBeaconAdvertisement(data: Data([0x8F, 0x03, 0x00]), deviceUUID: "1") == nil)

        // Xiaomi ID, 12..15 bytes (long enough for the guard, too short for payload)
        var truncated = Data([0x8F, 0x03])
        truncated.append(Data(repeating: 0x00, count: 11))
        #expect(decoder.decodeMiBeaconAdvertisement(data: truncated, deviceUUID: "1") == nil)
    }

    @Test("Service advertisement decode pins current byte layout")
    func decodeServiceAdvertisementCharacterization() {
        // bytes 0..1 temp x10 LE | 2 moisture | 3..4 brightness | 5..6 conductivity
        let data = Data([
            0xEF, 0x00,             // temperature raw 239 -> 23.9 °C
            0x33,                   // moisture 51
            0xB8, 0x01,             // brightness 440
            0xFB, 0x03,             // conductivity 1019
            0x00                    // padding to 8 bytes
        ])

        let result = decoder.decodeServiceAdvertisement(data: data, deviceUUID: "1")
        #expect(result?.temperature == 23.9)
        #expect(result?.moisture == 51)
        #expect(result?.brightness == 440)
        #expect(result?.conductivity == 1019)
    }

    @Test("Service advertisement decode rejects short data", arguments: [0, 1, 7])
    func decodeServiceAdvertisementShortData(length: Int) {
        let data = Data(repeating: 0x00, count: length)
        #expect(decoder.decodeServiceAdvertisement(data: data, deviceUUID: "1") == nil)
    }

    // MARK: - Robustness (seeded fuzz)

    /// Deterministic generator (SplitMix64) so a fuzz failure is reproducible
    /// from the seed in the test output.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test("No decode function crashes on fuzzed input", arguments: [UInt64(0xF10E5CA5E), UInt64(0xDEADBEEF), UInt64(42)])
    func decodersSurviveFuzzedInput(seed: UInt64) {
        decoder.setDeviceBootTime(bootTime: Date(), secondsSinceBoot: .max)
        var generator = SeededGenerator(state: seed)

        var inputs: [Data] = [
            Data(),
            Data([0x00]),
            Data(repeating: 0xFF, count: 16),
            Data(repeating: 0xFF, count: 64)
        ]
        for _ in 0..<500 {
            let length = Int.random(in: 0...64, using: &generator)
            inputs.append(Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        }

        for data in inputs {
            _ = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: "1")
            _ = decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1")
            _ = decoder.decodeHistoryMetadata(data: data)
            _ = decoder.decodeFirmwareAndBattery(data: data)
            _ = decoder.decodeDeviceName(data: data)
            _ = decoder.decodeDeviceTime(data: data)
            _ = decoder.decodeEntryCount(data: data)
            _ = decoder.decodeMiBeaconAdvertisement(data: data, deviceUUID: "1")
            _ = decoder.decodeServiceAdvertisement(data: data, deviceUUID: "1")
            _ = Data(hexString: String(decoding: data, as: UTF8.self))
        }

        // Reaching this point means no decoder crashed on malformed input
        #expect(Bool(true))
    }
}
