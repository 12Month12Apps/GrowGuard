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
        let data = Data([
            239, 0,                 // Temperature: 239 -> 23.9 °C
            3,                      // (skipped byte)
            185, 0, 0, 0,           // Brightness: 185 lux
            51,                     // Moisture: 51 %
            251, 3,                 // Conductivity: 0x03FB -> 1019 µS/cm
            2, 60, 0, 251, 52, 155  // Trailing bytes (unused)
        ])

        let sensorData = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: "1")
        #expect(sensorData != nil)
        #expect(sensorData?.temperature == 23.9)
        #expect(sensorData?.brightness == 185)
        #expect(sensorData?.moisture == 51)
        #expect(sensorData?.conductivity == 1019)
        #expect(sensorData?.device == "1")
    }

    @Test("Real-time decode rejects wrong lengths", arguments: [0, 1, 15, 17, 64])
    func decodeRealTimeSensorValuesInvalidLength(length: Int) {
        let data = Data(repeating: 0xAB, count: length)
        #expect(decoder.decodeRealTimeSensorValues(data: data, deviceUUID: "1") == nil)
    }

    // MARK: - Historical Sensor Data

    /// Builds a 14-byte history entry in the device's wire format:
    /// timestamp (4, LE) | temp x10 (2, LE) | skip (1) | brightness (4, LE) | moisture (1) | conductivity (2, LE)
    private func makeHistoryEntry(timestamp: UInt32,
                                  temperatureX10: UInt16,
                                  brightness: UInt32,
                                  moisture: UInt8,
                                  conductivity: UInt16) -> Data {
        var data = Data()
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: temperatureX10.littleEndian) { data.append(contentsOf: $0) }
        data.append(0x00) // skipped byte between temperature and brightness
        withUnsafeBytes(of: brightness.littleEndian) { data.append(contentsOf: $0) }
        data.append(moisture)
        withUnsafeBytes(of: conductivity.littleEndian) { data.append(contentsOf: $0) }
        return data
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
        var data = Data([0xC8, 0x00]) // 200 entries, little endian
        data.append(Data(repeating: 0x00, count: 14))

        let result = decoder.decodeHistoryMetadata(data: data)
        #expect(result?.entryCount == 200)
    }

    @Test("History metadata rejects implausible entry count")
    func decodeHistoryMetadataCorruptCount() {
        var data = Data([0x11, 0x27]) // 10001 entries -> above plausibility limit
        data.append(Data(repeating: 0x00, count: 14))

        #expect(decoder.decodeHistoryMetadata(data: data) == nil)
    }

    @Test("History metadata rejects short data")
    func decodeHistoryMetadataInvalidLength() {
        #expect(decoder.decodeHistoryMetadata(data: Data(repeating: 0x00, count: 15)) == nil)
    }

    // MARK: - Firmware and Battery

    @Test("Decode firmware version and battery level")
    func decodeFirmwareAndBattery() {
        // battery (1) | skipped (1) | firmware version ascii (5)
        let data = Data([0x50, 0x2A]) + "3.2.9".data(using: .ascii)!

        let result = decoder.decodeFirmwareAndBattery(data: data)
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
        let data = Data([0x10, 0x27, 0x00, 0x00]) // 10000 seconds, little endian
        #expect(decoder.decodeDeviceTime(data: data) == 10000)
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

    // MARK: - Robustness

    @Test("No decode function crashes on garbage input")
    func decodersSurviveGarbageInput() {
        decoder.setDeviceBootTime(bootTime: Date(), secondsSinceBoot: 1000)

        var garbage: [Data] = [
            Data(),
            Data([0x00]),
            Data(repeating: 0xFF, count: 16),
            Data(repeating: 0xFF, count: 64)
        ]
        var generator = SystemRandomNumberGenerator()
        for length in [2, 7, 14, 16, 32] {
            garbage.append(Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        }

        for data in garbage {
            _ = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: "1")
            _ = decoder.decodeHistoricalSensorData(data: data, deviceUUID: "1")
            _ = decoder.decodeHistoryMetadata(data: data)
            _ = decoder.decodeFirmwareAndBattery(data: data)
            _ = decoder.decodeDeviceName(data: data)
            _ = decoder.decodeDeviceTime(data: data)
            _ = decoder.decodeEntryCount(data: data)
            _ = decoder.decodeMiBeaconAdvertisement(data: data, deviceUUID: "1")
            _ = decoder.decodeServiceAdvertisement(data: data, deviceUUID: "1")
        }

        // Reaching this point means no decoder crashed on malformed input
        #expect(Bool(true))
    }
}
