//
//  AddDeviceBLE.swift
//  GrowGuard
//
//  Created by Veit Progl on 04.06.24.
//

import Foundation
import CoreBluetooth

class AddDeviceBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var realTimeSensorValuesCharacteristic: CBCharacteristic?
    var historyControlCharacteristic: CBCharacteristic?
    var historyDataCharacteristic: CBCharacteristic?
    var deviceTimeCharacteristic: CBCharacteristic?
    var entryCountCharacteristic: CBCharacteristic?

    var foundDevice: ((CBPeripheral) -> ())
    
    init(foundDevice: @escaping ((CBPeripheral) -> ())) {
        self.foundDevice = foundDevice

        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
        } else {
            print("Bluetooth is not available.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
//        if peripheral.name == "Flower care" {
//            centralManager.stopScan()
//            discoveredPeripheral = peripheral
//            discoveredPeripheral?.delegate = self
//            centralManager.connect(discoveredPeripheral!, options: nil)
//            print("Flower Care Sensor found. Connecting...")
//        }
        foundDevice(peripheral)
    }

//    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
//        peripheral.delegate = self
//        peripheral.discoverServices([dataServiceUUID, historyServiceUUID])
//    }
//
//    // MARK: - CBPeripheralDelegate Methods
//    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
//        if let deviceName = peripheral.name {
//            print("Discovered device: \(deviceName), UUID: \(peripheral.identifier)")
//        }
//        
//        if let services = peripheral.services {
//            for service in services {
//                peripheral.discoverCharacteristics(nil, for: service)
//            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
//        if let characteristics = service.characteristics {
//            for characteristic in characteristics {
//                switch characteristic.uuid {
//                case deviceModeChangeCharacteristicUUID:
//                    let modeChangeCommand: [UInt8] = [0xa0, 0x1f]
//                    let modeChangeData = Data(modeChangeCommand)
//                    peripheral.writeValue(modeChangeData, for: characteristic, type: .withResponse)
//                case realTimeSensorValuesCharacteristicUUID:
//                    realTimeSensorValuesCharacteristic = characteristic
//                    peripheral.readValue(for: characteristic)
//                case firmwareVersionCharacteristicUUID:
//                    peripheral.readValue(for: characteristic)
//                case deviceNameCharacteristicUUID:
//                    peripheral.readValue(for: characteristic)
////                case historyControlCharacteristicUUID:
////                    historyControlCharacteristic = characteristic
////                case historyDataCharacteristicUUID:
////                    historyDataCharacteristic = characteristic
//                case deviceTimeCharacteristicUUID:
//                    deviceTimeCharacteristic = characteristic
//                    peripheral.readValue(for: characteristic)
////                case entryCountCharacteristicUUID:
////                    entryCountCharacteristic = characteristic
////                    peripheral.readValue(for: characteristic)
//                default:
//                    break
//                }
//            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
//        if let error = error {
//            print("Error writing value: \(error.localizedDescription)")
//            return
//        }
//
//        if characteristic.uuid == deviceModeChangeCharacteristicUUID {
//            if let realTimeCharacteristic = realTimeSensorValuesCharacteristic {
//                peripheral.readValue(for: realTimeCharacteristic)
//            }
////        } else if characteristic.uuid == historyControlCharacteristicUUID {
////            if let historyDataCharacteristic = historyDataCharacteristic {
////                peripheral.readValue(for: historyDataCharacteristic)
////            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        guard error == nil else {
//            print("Error reading characteristic: \(error!.localizedDescription)")
//            return
//        }
//
//        if let value = characteristic.value {
//            switch characteristic.uuid {
//            case realTimeSensorValuesCharacteristicUUID:
//                decodeRealTimeSensorValues(data: value)
//            case firmwareVersionCharacteristicUUID:
//                decodeFirmwareAndBattery(data: value)
//            case deviceNameCharacteristicUUID:
//                decodeDeviceName(data: value)
//            case deviceTimeCharacteristicUUID:
//                decodeDeviceTime(data: value)
////            case entryCountCharacteristicUUID:
////                decodeEntryCount(data: value)
////            case historyDataCharacteristicUUID:
////                decodeHistoryData(data: value)
//            default:
//                break
//            }
//        }
//    }
//
//    private func decodeDeviceName(data: Data) {
//        if let deviceName = String(data: data, encoding: .ascii) {
//            print("Device Name: \(deviceName)")
//        } else {
//            print("Failed to decode device name.")
//        }
//    }
//
//    private func decodeFirmwareAndBattery(data: Data) {
//        guard data.count == 7 else {
//            print("Unexpected data length: \(data.count)")
//            return
//        }
//
//        let batteryLevel = data[0]
//        if let firmwareVersion = String(data: data[1..<7], encoding: .ascii) {
//            print("Battery Level: \(batteryLevel) %")
//            print("Firmware Version: \(firmwareVersion)")
//        } else {
//            print("Failed to decode firmware version.")
//        }
//    }
//
//    private func decodeRealTimeSensorValues(data: Data) {
//        guard data.count == 16 else {
//            print("Unexpected data length: \(data.count)")
//            return
//        }
//
//        let temperature = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
//        let brightness = data.subdata(in: 3..<7).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
//        let moisture = data[7]
//        let conductivity = data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
//
//        let temperatureCelsius = Double(temperature) / 10.0
//
//        print("Temperature: \(temperatureCelsius) °C")
//        print("Brightness: \(brightness) lux")
//        print("Soil Moisture: \(moisture) %")
//        print("Soil Conductivity: \(conductivity) µS/cm")
//    }
//
//    private func decodeDeviceTime(data: Data) {
//        guard data.count == 4 else {
//            print("Unexpected data length: \(data.count)")
//            return
//        }
//
//        let deviceTime = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
//        print("Device Time: \(deviceTime) seconds since device epoch")
//    }

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
