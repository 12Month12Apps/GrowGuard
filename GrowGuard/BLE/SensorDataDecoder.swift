//
//  SensorDataDecoder.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

class SensorDataDecoder {
    
    func decodeRealTimeSensorValues(data: Data) -> SensorData? {
        guard data.count == 16 else {
            print("Unexpected data length: \(data.count)")
            return nil
        }

        let temperature = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        let brightness = data.subdata(in: 3..<7).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let moisture = data[7]
        let conductivity = data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian

        let temperatureCelsius = Double(temperature) / 10.0

        print("Temperature: \(temperatureCelsius) °C")
        print("Brightness: \(brightness) lux")
        print("Soil Moisture: \(moisture) %")
        print("Soil Conductivity: \(conductivity) µS/cm")
        
        return SensorData(
            temperature: temperatureCelsius,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity,
            date: Date()
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

    func decodeFirmwareAndBattery(data: Data) {
        guard data.count == 7 else {
            print("Unexpected data length: \(data.count)")
            return
        }

        let batteryLevel = data[0]
        if let firmwareVersion = String(data: data[1..<7], encoding: .ascii) {
            print("Battery Level: \(batteryLevel) %")
            print("Firmware Version: \(firmwareVersion)")
        } else {
            print("Failed to decode firmware version.")
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
