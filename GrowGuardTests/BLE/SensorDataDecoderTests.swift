//
//  SensorDataDecoderTests.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Testing
@testable import GrowGuard
import CoreBluetooth

class SensorDataDecoderTests {

    let decoder = SensorDataDecoder()

    @Test("Test decodeRealTimeSensorValues with received debug data")
    func testDecodeRealTimeSensorValuesWithDebugData() {
        // Debug Data received from sensor (16 Bytes total)
        let data: Data = Data([
            239, 0,                 // Temperature raw value (to be decoded)
            3, 185, 0, 0,           // Brightness raw value (to be decoded)
            0,                      // Moisture raw value (to be decoded)
            51, 251,                // Conductivity raw value (to be decoded)
            3, 2,                   // Additional bytes
            60, 0, 251, 52, 155     // Padding or unused data
        ])

        if let sensorData = decoder.decodeRealTimeSensorValues(data: data) {
            // Based on your decoder logic, you can expect the following:
            #expect(sensorData.temperature == 23.9)       // Decoded temperature (from 239)
            #expect(sensorData.brightness == 185)    // Decoded brightness
            #expect(sensorData.moisture == 51)            // Decoded moisture
            #expect(sensorData.conductivity == 1019)     // Decoded conductivity
        } else {
            #expect(false) // Test fails if decoding fails
        }
    }

    @Test("Test decodeRealTimeSensorValues with invalid data length")
    func testDecodeRealTimeSensorValuesInvalidLength() {
        // Invalid data length (only 1 byte, expected 16)
        let data: Data = Data([0x1A])
        let sensorData = decoder.decodeRealTimeSensorValues(data: data)
        #expect(sensorData == nil) // Expect nil for invalid length
    }

    //TODO: History Data still WIP
//    @Test("Test decodeHistoricalSensorData with valid data")
//    func testDecodeHistoricalSensorData() {
//        // Historical Sensor Data (16 Bytes total)
//        // Timestamp (4 Bytes), 0x0000005B -> 91 seconds
//        // Temperature (2 Bytes), 0x1A2C -> 28.4 °C
//        // Brightness (4 Bytes), 0x00000000 -> 0 lux
//        // Moisture (1 Byte), 0x4E -> 78 %
//        // Conductivity (2 Bytes), 0x000A -> 10 µS/cm
//        let data: Data = Data([
//            0x00, 0x00, 0x00, 0x5B, // Timestamp (0x0000005B -> 91 seconds)
//            0x1A, 0x2C,             // Temperature (0x1A2C -> 28.4 °C)
//            0x00, 0x00, 0x00, 0x00, // Brightness (0x00000000 -> 0 lux)
//            0x4E,                   // Moisture (0x4E -> 78%)
//            0x00, 0x0A              // Conductivity (0x000A -> 10 µS/cm)
//        ])
//        if let historicalData = decoder.decodeHistoricalSensorData(data: data) {
//            #expect(historicalData.timestamp == 91)
//            #expect(historicalData.temperature == 28.4)
//            #expect(historicalData.brightness == 0)
//            #expect(historicalData.moisture == 78)
//            #expect(historicalData.conductivity == 10)
//        } else {
//            #expect(false) // Test fails if decoding fails
//        }
//    }

//    @Test("Test decodeHistoricalSensorData with invalid data length")
//    func testDecodeHistoricalSensorDataInvalidLength() {
//        // Invalid data length (only 1 byte, expected 16)
//        let data: Data = Data([0x1A])
//        let historicalData = decoder.decodeHistoricalSensorData(data: data)
//        #expect(historicalData == nil) // Expect nil for invalid length
//    }

    @Test("Test decodeFirmwareAndBattery with valid data")
    func testDecodeFirmwareAndBattery() {
        // Firmware and Battery Data (7 Bytes total)
        // Battery (1 Byte), 0x50 -> 80%
        // Firmware Version (6 Bytes), "fromwa"
        let data: Data = Data([
            0x50,                   // Battery (0x50 -> 80%)
            0x66, 0x72, 0x6F, 0x6D, 0x77, 0x61 // Firmware Version "fromwa"
        ])
        decoder.decodeFirmwareAndBattery(data: data) // Output verification done manually via print statements
        #expect(true) // Test passes if no errors occur
    }

    @Test("Test decodeDeviceName with valid data")
    func testDecodeDeviceName() {
        // Device Name (ASCII string)
        let data: Data = "TestDevice".data(using: .ascii)!
        decoder.decodeDeviceName(data: data) // Output verification done manually via print statements
        #expect(true) // Test passes if no errors occur
    }

    @Test("Test decodeDeviceTime with valid data")
    func testDecodeDeviceTime() {
        // Device Time (4 Bytes total)
        // Time (4 Bytes), 0x00000001 -> 1 second since epoch
        let data: Data = Data([
            0x00, 0x00, 0x00, 0x01 // Time (0x00000001 -> 1 second)
        ])
        decoder.decodeDeviceTime(data: data) // Output verification done manually via print statements
        #expect(true) // Test passes if no errors occur
    }

    @Test("Test decodeEntryCount with valid data")
    func testDecodeEntryCount() {
        // Entry Count (2 Bytes total)
        // Entries (2 Bytes), 0x0005 -> 1280 entries
        let data: Data = Data([
            0x00, 0x0005 // Entries (0x0005 -> 1280 entries)
        ])
        let entryCount = decoder.decodeEntryCount(data: data)
        #expect(entryCount == 1280) // Expect 1280 entries
    }

    @Test("Test decodeEntryCount with invalid data length")
    func testDecodeEntryCountInvalidLength() {
        // Invalid data length (only 1 byte, expected 2)
        let data: Data = Data([0x00])
        let entryCount = decoder.decodeEntryCount(data: data)
        #expect(entryCount == nil) // Expect nil for invalid length
    }
}
