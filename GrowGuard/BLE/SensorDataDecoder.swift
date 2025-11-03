//
//  SensorDataDecoder.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

class SensorDataDecoder {
    
    private var deviceBootTime: Date?
    private var secondsSinceBoot: UInt32?

    func setDeviceBootTime(bootTime: Date?, secondsSinceBoot: UInt32) {
        self.deviceBootTime = bootTime
        self.secondsSinceBoot = secondsSinceBoot
    }
    
    func decodeRealTimeSensorValues(data: Data, deviceUUID: String) -> SensorDataTemp? {
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
            deviceUUID: deviceUUID
        )
    }

    func decodeHistoricalSensorData(data: Data, deviceUUID: String) -> HistoricalSensorData? {
        // Check if data is at least 12 bytes long (4+2+4+1+2+1) 1 is skipped
        guard data.count >= 14 else {
            print("❌ Historical data too short: \(data.count) bytes")
            return nil
        }

        // Log raw bytes for debugging
        let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("📦 Raw historical data (\(data.count) bytes): \(hexString)")

        guard let secondsSinceBoot = secondsSinceBoot else {
            print("❌ secondsSinceBoot not available - device time not read yet")
            return nil
        }


        // Extract timestamp (4 bytes)
        let timestamp = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian

        // Validate timestamp
        if secondsSinceBoot < timestamp {
            print("❌ Invalid timestamp: \(timestamp) > secondsSinceBoot: \(secondsSinceBoot)")
            return nil
        }

        let now = Date()
        let secondsAgo = secondsSinceBoot - timestamp
        let dateTime = now.addingTimeInterval(-Double(secondsAgo))

        // Extract temperature (2 bytes) and convert to Celsius
        let temperatureRaw = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        let temperature = Double(temperatureRaw) / 10.0

        // Extract brightness (4 bytes)
        let brightness = data.subdata(in: 7..<11).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian

        // Extract moisture (1 byte)
        let moisture = UInt8(data[11])

        // Extract conductivity (2 bytes)
        let conductivity = data.subdata(in: 12..<14).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian

        print("✅ Decoded historic data: temp=\(temperature)°C, moisture=\(moisture)%, brightness=\(brightness)lx, conductivity=\(conductivity)µS/cm, date=\(dateTime) (timestamp=\(timestamp), secondsAgo=\(secondsAgo))")

        return HistoricalSensorData(
            deviceUUID: deviceUUID,
            timestamp: timestamp,
            temperature: temperature,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: dateTime
        )
    }

    // Add this to your SensorDataDecoder class
    func decodeHistoryMetadata(data: Data) -> (entryCount: Int, additionalInfo: [String: Any])? {
        guard data.count >= 16 else {
            print("❌ History metadata data too short: \(data.count) bytes")
            return nil
        }
        
        print("📊 Decoding history metadata from \(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined())")
        
        // Extract entry count (first 2 bytes, little-endian)
        let entryCount = Int(data[0]) | (Int(data[1]) << 8)
        print("📊 Extracted entry count: \(entryCount)")
        
        // Validate entry count is reasonable (not corrupted)
        if entryCount < 0 || entryCount > 10000 {
            print("❌ Invalid entry count: \(entryCount) - likely corrupted metadata")
            return nil
        }
        
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
    
    func decodeMiBeaconAdvertisement(data: Data, deviceUUID: String) -> SensorDataTemp? {
        guard data.count >= 12 else {
            print("MiBeacon data too short: \(data.count)")
            return nil
        }
        
        // Check for Xiaomi manufacturer ID (0x038F)
        let manufacturerID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        guard manufacturerID == 0x038F else {
            print("Not a Xiaomi MiBeacon packet")
            return nil
        }
        
        // Skip Xiaomi header and look for FlowerCare data
        // This is a simplified implementation - real MiBeacon parsing is more complex
        if data.count >= 16 {
            let temperature = Double(UInt16(data[8]) | (UInt16(data[9]) << 8)) / 10.0
            let moisture = data[10]
            let brightness = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
            let conductivity = UInt16(data[11]) | (UInt16(data[12]) << 8)
            
            return SensorDataTemp(
                temperature: temperature,
                brightness: brightness,
                moisture: moisture,
                conductivity: conductivity,
                date: Date(),
                deviceUUID: deviceUUID
            )
        }
        
        return nil
    }
    
    func decodeServiceAdvertisement(data: Data, deviceUUID: String) -> SensorDataTemp? {
        guard data.count >= 8 else {
            print("Service advertisement data too short: \(data.count)")
            return nil
        }
        
        // Try to extract sensor data from service advertisement
        // This is a basic implementation - might need adjustment based on actual format
        let temperature = Double(UInt16(data[0]) | (UInt16(data[1]) << 8)) / 10.0
        let moisture = data[2]
        let brightness = UInt32(data[3]) | (UInt32(data[4]) << 8)
        let conductivity = UInt16(data[5]) | (UInt16(data[6]) << 8)
        
        return SensorDataTemp(
            temperature: temperature,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: Date(),
            deviceUUID: deviceUUID
        )
    }
}
