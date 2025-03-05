//
//  SensorDataDecoder.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

class SensorDataDecoder {
    
    func decodeRealTimeSensorValues(data: Data, device: FlowerDevice?) -> SensorData? {
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
        
        return SensorData(
            temperature: temperatureCelsius,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: Date(),
            device: device
        )
    }

    func decodeHistoricalSensorData(data: Data) -> HistoricalSensorData? {
        guard data.count == 16 else {
            print("Unexpected data length: \(data.count)")
            return nil
        }

        let timestamp = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let temperature = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        let brightness = data.subdata(in: 7..<11).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let moisture = data[11]
        let conductivity = data.subdata(in: 12..<14).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian

        let temperatureCelsius = Double(temperature) / 10.0

        print("Timestamp: \(timestamp) seconds since device epoch")
        print("Temperature: \(temperatureCelsius) °C")
        print("Brightness: \(brightness) lux")
        print("Soil Moisture: \(moisture) %")
        print("Soil Conductivity: \(conductivity) µS/cm")
        
        return HistoricalSensorData(
            timestamp: timestamp,
            temperature: temperatureCelsius,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity
        )
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
