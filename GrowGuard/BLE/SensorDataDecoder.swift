//
//  SensorDataDecoder.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

class SensorDataDecoder {
    
    private var deviceBootTime: Date?

    func setDeviceBootTime(_ bootTime: Date?) {
        self.deviceBootTime = bootTime
    }
    
    func decodeRealTimeSensorValues(data: Data, device: FlowerDevice?) -> SensorDataTemp? {
        guard data.count == 16 else {
            print("Unexpected data length: \(data.count)")
            return nil
        }

        // Ausführlicheres Debug-Logging
        let hexString = data.map { String(format: "%02X", $0) }.joined()
        print("Raw data (hex): \(hexString)")
        print("Raw temperature bytes: [0]=\(data[0]) (hex: \(String(format: "%02X", data[0]))), [1]=\(data[1]) (hex: \(String(format: "%02X", data[1])))")
        
        // Verschiedene Interpretationen probieren
        let tempLowByte = UInt16(data[0])
        let tempHighByte = UInt16(data[1])
        let temperatureRaw = tempLowByte + (tempHighByte << 8)
        let temperatureCelsius = Double(temperatureRaw) / 10.0

        let brightness = data.subdata(in: 3..<7).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let moisture = data.subdata(in: 7..<8).withUnsafeBytes { $0.load(as: UInt8.self) }.littleEndian
        let conductivity = data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        
        return SensorDataTemp(
            temperature: temperatureCelsius,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: Date(),
            device: device
        )
    }

    func decodeHistoricalSensorData(data: Data) -> HistoricalSensorData? {
        // Check if data is at least 13 bytes long (4+2+4+1+2)
        guard data.count >= 13 else {
            print("Historical data too short: \(data.count) bytes")
            return nil
        }
        
        // Extract timestamp (4 bytes)
        let timestamp = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        // Extract temperature (2 bytes) and convert to Celsius
        let temperatureRaw = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }
        let temperature = Double(temperatureRaw) / 10.0
        
        // Extract brightness (4 bytes)
        let brightness = data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        // Extract moisture (1 byte)
        let moisture = data[10]
        
        // Extract conductivity (2 bytes)
        let conductivity = data.subdata(in: 11..<13).withUnsafeBytes { $0.load(as: UInt16.self) }
        
        print("Historic:", timestamp, moisture, temperature, conductivity)
        
        return HistoricalSensorData(
            timestamp: timestamp,
            temperature: temperature,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity
        )
    }

    // Add this to your SensorDataDecoder class
    func decodeHistoryMetadata(data: Data) -> (entryCount: Int, additionalInfo: [String: Any])? {
        guard data.count >= 16 else {
            print("History metadata data too short")
            return nil
        }
        
        // Extract entry count (first 2 bytes, little-endian)
        let entryCount = Int(data[0]) | (Int(data[1]) << 8)
        
        // Parse the remaining bytes - this is a best guess based on common patterns
        // Bytes 2-5 and 6-9 could be timestamps or indexes
        let timestamp1 = UInt32(data[2]) | (UInt32(data[3]) << 8) | (UInt32(data[4]) << 16) | (UInt32(data[5]) << 24)
        let timestamp2 = UInt32(data[6]) | (UInt32(data[7]) << 8) | (UInt32(data[8]) << 16) | (UInt32(data[9]) << 24)
        
        // Bytes 10-13 might be another value
        let value3 = UInt32(data[10]) | (UInt32(data[11]) << 8) | (UInt32(data[12]) << 16) | (UInt32(data[13]) << 24)
        
        // Create a dictionary with the parsed values
        let additionalInfo: [String: Any] = [
            "possibleTimestamp1": timestamp1,
            "possibleTimestamp2": timestamp2,
            "unknownValue": value3,
            "rawData": data.map { String(format: "%02x", $0) }.joined()
        ]
        
        print("History metadata: \(entryCount) entries, additional data: \(additionalInfo)")
        return (entryCount, additionalInfo)
    }

    func decodeFirmwareAndBattery(data: Data) -> (batteryLevel: UInt8, firmwareVersion: String)? {
        guard data.count == 7 else {
            print("Unexpected data length: \(data.count)")
            return nil
        }

        let batteryLevel = data.subdata(in: 0..<1).withUnsafeBytes { $0.load(as: UInt8.self) }.littleEndian
        if let firmwareVersion = String(data: data[2..<7], encoding: .ascii) {
            print("Battery Level: \(batteryLevel) %")
            print("Firmware Version: \(firmwareVersion)")
            return (batteryLevel, firmwareVersion)
        } else {
            print("Failed to decode firmware version.")
            return nil
        }
    }

    func decodeDeviceName(data: Data) {
        if let deviceName = String(data: data, encoding: .ascii) {
            print("Device Name: \(deviceName)")
        } else {
            print("Failed to decode device name.")
        }
    }

    func decodeDeviceTime(data: Data) {
        guard data.count == 4 else {
            print("Unexpected data length: \(data.count)")
            return
        }

        let deviceTime = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        print("Device Time: \(deviceTime) seconds since device epoch")
    }

    func decodeEntryCount(data: Data) -> Int? {
        guard data.count == 2 else {
            print("Unexpected data length: \(data.count)")
            return nil
        }
        
        return Int(data.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian)
    }
}
