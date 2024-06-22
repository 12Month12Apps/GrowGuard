//
//  FlowerManager.swift
//  GrowGuard
//
//  Created by Veit Progl on 02.06.24.
//

import Foundation
import CoreBluetooth
import Combine

struct SensorData {
    let temperature: Double
    let brightness: UInt32
    let moisture: UInt8
    let conductivity: UInt16
}

let flowerCareServiceUUID = CBUUID(string: "0000fe95-0000-1000-8000-00805f9b34fb")
let dataServiceUUID = CBUUID(string: "00001204-0000-1000-8000-00805f9b34fb")
let historyServiceUUID = CBUUID(string: "00001206-0000-1000-8000-00805f9b34fb")

let deviceNameCharacteristicUUID = CBUUID(string: "00002a00-0000-1000-8000-00805f9b34fb")
let realTimeSensorValuesCharacteristicUUID = CBUUID(string: "00001a01-0000-1000-8000-00805f9b34fb")
let firmwareVersionCharacteristicUUID = CBUUID(string: "00001a02-0000-1000-8000-00805f9b34fb")
let deviceModeChangeCharacteristicUUID = CBUUID(string: "00001a00-0000-1000-8000-00805f9b34fb")
let historicalSensorValuesCharacteristicUUID = CBUUID(string: "00001a11-0000-1000-8000-00805f9b34fb")
let deviceTimeCharacteristicUUID = CBUUID(string: "00001a12-0000-1000-8000-00805f9b34fb")

class FlowerCareManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var realTimeSensorValuesCharacteristic: CBCharacteristic?
    var historyControlCharacteristic: CBCharacteristic?
    var historyDataCharacteristic: CBCharacteristic?
    var deviceTimeCharacteristic: CBCharacteristic?
    var entryCountCharacteristic: CBCharacteristic?
    private var isScanning = false
    private var device: FlowerDevice?
    
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
        
    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        return sensorDataSubject.eraseToAnyPublisher()
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    
    // Startet die Bluetooth-Suche
    func startScanning(device: FlowerDevice) {
        self.device = device
        guard let centralManager = centralManager else { return }
        if !isScanning && centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            isScanning = true
            print("Scanning started")
        }
    }

    // Stoppt die Bluetooth-Suche
    func stopScanning() {
        guard let centralManager = centralManager else { return }
        if isScanning {
            centralManager.stopScan()
            isScanning = false
            print("Scanning stopped")
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            print("Bluetooth is not available.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
//        if peripheral.name == "Flower care" {
        if peripheral.identifier.uuidString == device?.uuid {
            centralManager.stopScan()
            discoveredPeripheral = peripheral
            discoveredPeripheral?.delegate = self
            centralManager.connect(discoveredPeripheral!, options: nil)
            print("Flower Care Sensor found. Connecting...")
        }
        
//        if discoveredPeripheral != peripheral {
//            discoveredPeripheral = peripheral
//            centralManager.connect(peripheral, options: nil)
//        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([dataServiceUUID, historyServiceUUID])
    }

    // MARK: - CBPeripheralDelegate Methods
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let deviceName = peripheral.name {
            print("Discovered device: \(deviceName), UUID: \(peripheral.identifier)")
        }
        
        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                switch characteristic.uuid {
                case deviceModeChangeCharacteristicUUID:
                    let modeChangeCommand: [UInt8] = [0xa0, 0x1f]
                    let modeChangeData = Data(modeChangeCommand)
                    peripheral.writeValue(modeChangeData, for: characteristic, type: .withResponse)
                case realTimeSensorValuesCharacteristicUUID:
                    realTimeSensorValuesCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                case firmwareVersionCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                case deviceNameCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
//                case historyControlCharacteristicUUID:
//                    historyControlCharacteristic = characteristic
//                case historyDataCharacteristicUUID:
//                    historyDataCharacteristic = characteristic
                case deviceTimeCharacteristicUUID:
                    deviceTimeCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
//                case entryCountCharacteristicUUID:
//                    entryCountCharacteristic = characteristic
//                    peripheral.readValue(for: characteristic)
                default:
                    break
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error writing value: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == deviceModeChangeCharacteristicUUID {
            if let realTimeCharacteristic = realTimeSensorValuesCharacteristic {
                peripheral.readValue(for: realTimeCharacteristic)
            }
//        } else if characteristic.uuid == historyControlCharacteristicUUID {
//            if let historyDataCharacteristic = historyDataCharacteristic {
//                peripheral.readValue(for: historyDataCharacteristic)
//            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            print("Error reading characteristic: \(error!.localizedDescription)")
            return
        }

        if let value = characteristic.value {
            switch characteristic.uuid {
            case realTimeSensorValuesCharacteristicUUID:
                decodeRealTimeSensorValues(data: value)
            case firmwareVersionCharacteristicUUID:
                decodeFirmwareAndBattery(data: value)
            case deviceNameCharacteristicUUID:
                decodeDeviceName(data: value)
            case deviceTimeCharacteristicUUID:
                decodeDeviceTime(data: value)
//            case entryCountCharacteristicUUID:
//                decodeEntryCount(data: value)
//            case historyDataCharacteristicUUID:
//                decodeHistoryData(data: value)
            default:
                break
            }
        }
    }

    private func decodeDeviceName(data: Data) {
        if let deviceName = String(data: data, encoding: .ascii) {
            print("Device Name: \(deviceName)")
        } else {
            print("Failed to decode device name.")
        }
    }

    private func decodeFirmwareAndBattery(data: Data) {
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

    private func decodeRealTimeSensorValues(data: Data) {
        guard data.count == 16 else {
            print("Unexpected data length: \(data.count)")
            return
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
        
        let sensorData = SensorData(
            temperature: temperatureCelsius,
            brightness: brightness,
            moisture: moisture,
            conductivity: conductivity
        )
        
        sensorDataSubject.send(sensorData)
    }

    private func decodeDeviceTime(data: Data) {
        guard data.count == 4 else {
            print("Unexpected data length: \(data.count)")
            return
        }

        let deviceTime = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        print("Device Time: \(deviceTime) seconds since device epoch")
    }

//    private func decodeEntryCount(data: Data) {
//        guard data.count == 16 else {
//            print("Unexpected data length: \(data.count)")
//            return
//        }
//
//        let entryCount = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
//        print("Number of stored historical records: \(entryCount)")
//
//        // Read each entry
//        for i in 0..<entryCount {
//            let entryAddress = Data([0xa1, UInt8(i & 0xff), UInt8((i >> 8) & 0xff)])
//            if let historyControlCharacteristic = historyControlCharacteristic {
//                discoveredPeripheral?.writeValue(entryAddress, for: historyControlCharacteristic, type: .withResponse)
//            }
//        }
//    }
//
//    private func decodeHistoryData(data: Data) {
//        guard data.count == 16 else {
//            print("Unexpected data length: \(data.count)")
//            return
//        }
//
//        let timestamp = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
//        let temperature = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
//        let brightness = data.subdata(in: 7..<11).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
//        let moisture = data[11]
//        let conductivity = data.subdata(in: 12..<14).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
//
//        let temperatureCelsius = Double(temperature) / 10.0
//
//        print("Timestamp: \(timestamp) seconds since device epoch")
//        print("Temperature: \(temperatureCelsius) °C")
//        print("Brightness: \(brightness) lux")
//        print("Soil Moisture: \(moisture) %")
//        print("Soil Conductivity: \(conductivity) µS/cm")
//    }
}
