//
//  FlowerCase.swift
//  GrowGuard
//
//  Created by Veit Progl on 01.05.24.
//

import Foundation
import CoreBluetooth

class FlowerCareManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var flowerCarePeripheral: CBPeripheral?
    private let flowerCareCharacteristicUUID = CBUUID(string: "0001")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            print("Scanning for Flower Care Sensor...")
        } else {
            print("Bluetooth is not available")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name == "Flower care" {
            centralManager.stopScan()
            flowerCarePeripheral = peripheral
            flowerCarePeripheral?.delegate = self
            centralManager.connect(flowerCarePeripheral!, options: nil)
            print("Flower Care Sensor found. Connecting...")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to Flower Care Sensor")
        print(peripheral)
//        flowerCarePeripheral = peripheral
//        flowerCarePeripheral?.delegate = self
//        peripheral.discoverServices([serviceUUID])

        requestDataUpdate()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            print("No services discovered")
            return
        }

        for service in services {
            peripheral.discoverCharacteristics([flowerCareCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            print("No characteristics discovered")
            return
        }

        for characteristic in characteristics {
            if characteristic.uuid == flowerCareCharacteristicUUID {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating value for characteristic: \(error.localizedDescription)")
            return
        }

        if let value = characteristic.value {
            // Handle the received data from the Flower Care Sensor
            parseAndPrintData(value)
        }
    }

    private func parseAndPrintData(_ data: Data) {
        let temperature = Double(data[0]) + Double(data[1]) / 10.0
        let moisture = Int(data[2])
        let light = Int(data[3]) << 8 + Int(data[4])
        let conductivity = Int(data[5]) << 8 + Int(data[6])
        
        print("Temperature: \(temperature)°C")
        print("Moisture: \(moisture)%")
        print("Light: \(light) lux")
        print("Conductivity: \(conductivity) µS/cm")
    }

    func readDeviceName() {
        guard let peripheral = flowerCarePeripheral else { return }
        readCharacteristic(peripheral, handle: 0x03)
    }
    
    func readFirmwareVersion() {
        guard let peripheral = flowerCarePeripheral else { return }
        readCharacteristic(peripheral, handle: 0x38)
    }
    
    func readBatteryLevel() {
        guard let peripheral = flowerCarePeripheral else { return }
        readCharacteristic(peripheral, handle: 0x38)
    }
    
    func readRealTimeData() {
        guard let peripheral = flowerCarePeripheral else { return }
        writeHandle(peripheral, handle: 0x33, command: Data([0xa0, 0x1f]))
        readCharacteristic(peripheral, handle: 0x35)
    }
    
    func readHistoricalData() {
        guard let peripheral = flowerCarePeripheral else { return }
        writeHandle(peripheral, handle: 0x3e, command: Data([0xa0, 0x00, 0x00]))
        readCharacteristic(peripheral, handle: 0x3c)
    }
    
    func clearHistory() {
        guard let peripheral = flowerCarePeripheral else { return }
        writeHandle(peripheral, handle: 0x3e, command: Data([0xa2, 0x00, 0x00]))
    }
    
    func blinkLED() {
        guard let peripheral = flowerCarePeripheral else { return }
        writeHandle(peripheral, handle: 0x33, command: Data([0xfd, 0xff]))
    }
    
    private func readCharacteristic(_ peripheral: CBPeripheral, handle: UInt16) {
        peripheral.readValue(for: characteristicWithHandle(handle))
    }
    
    private func writeHandle(_ peripheral: CBPeripheral, handle: UInt16, command: Data) {
        peripheral.writeValue(command, for: characteristicWithHandle(handle), type: .withResponse)
    }
    
    private func characteristicWithHandle(_ handle: UInt16) -> CBCharacteristic {
        guard let service = flowerCarePeripheral?.services?.first(where: { $0.uuid == CBUUID(nsuuid: flowerCarePeripheral!.identifier) }),
              let characteristic = service.characteristics?.first(where: { $0.uuid == flowerCareCharacteristicUUID }) else {
                fatalError("Service or characteristic not found")
            }
        return characteristic
    }
    
    func requestDataUpdate() {
//        guard let flowerCarePeripheral = flowerCarePeripheral else {
//            print("Flower Care Peripheral not found")
//            return
//        }
//
//        guard let services = flowerCarePeripheral.services, !services.isEmpty else {
//            print("No services available")
//            return
//        }
//
//        guard let service = services.first else {
//            print("No first service found")
//            return
//        }
//
//        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
//            print("No characteristics available")
//            return
//        }
//
//        guard let characteristic = characteristics.first(where: { $0.uuid == flowerCareCharacteristicUUID }) else {
//            print("Flower Care Characteristic not found")
//            return
//        }
//
//        flowerCarePeripheral.readValue(for: characteristic)
        readDeviceName()
        readBatteryLevel()
        readHistoricalData()
        readFirmwareVersion()
        readRealTimeData()
    }
}


import Foundation
import CoreBluetooth

//struct BLEUUIDs {
//    static let serviceAdvertisementUUID = CBUUID(string: "0000fe95-0000-1000-8000-00805f9b34fb")
//    static let serviceBatteryFirmwareRealTimeDataUUID = CBUUID(string: "00001204-0000-1000-8000-00805f9b34fb")
//    static let characteristicReadRequestToRealTimeDataUUID = CBUUID(string: "00001a00-0000-1000-8000-00805f9b34fb")
//    static let characteristicRealTimeDataUUID = CBUUID(string: "00001a01-0000-1000-8000-00805f9b34fb")
//    static let characteristicFirmwareAndBatteryUUID = CBUUID(string: "00001a02-0000-1000-8000-00805f9b34fb")
//    static let serviceHistoricalDataUUID = CBUUID(string: "00001206-0000-1000-8000-00805f9b34fb")
//    static let characteristicReadRequestToHistoricalDataUUID = CBUUID(string: "00001a10-0000-1000-8000-00805f9b34fb")
//    static let characteristicHistoricalDataUUID = CBUUID(string: "00001a11-0000-1000-8000-00805f9b34fb")
//    static let characteristicEpochTimeUUID = CBUUID(string: "00001a12-0000-1000-8000-00805f9b34fb")
//}

//class BLEManagerf: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
//    var centralManager: CBCentralManager!
//    var connectedPeripheral: CBPeripheral?
//
//    override init() {
//        super.init()
//        centralManager = CBCentralManager(delegate: self, queue: nil)
//    }
//
//    func centralManagerDidUpdateState(_ central: CBCentralManager) {
//        if central.state == .poweredOn {
//            central.scanForPeripherals(withServices: [BLEUUIDs.serviceAdvertisementUUID], options: nil)
//        } else {
//            print("Bluetooth is not available.")
//        }
//    }
//
//    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
//        print("Discovered \(peripheral.name ?? "Unnamed") at \(RSSI)")
//        if peripheral.name == "Flower care" || advertisementData[CBAdvertisementDataServiceUUIDsKey] != nil {
//            central.stopScan()
//            connectedPeripheral = peripheral
//            central.connect(peripheral, options: nil)
//        }
//    }
//
//    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
//        print("Connected to \(peripheral.name ?? "Unnamed")")
//        peripheral.discoverServices([BLEUUIDs.serviceBatteryFirmwareRealTimeDataUUID, BLEUUIDs.serviceHistoricalDataUUID])
//    }
//
//    // Implement additional delegate methods as needed
//}
//
//extension BLEManagerf {
//
//    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
//        guard error == nil else {
//            print("Error discovering services: \(error!.localizedDescription)")
//            return
//        }
//
//        if let services = peripheral.services {
//            for service in services {
//                if service.uuid == BLEUUIDs.serviceHistoricalDataUUID {
//                    peripheral.discoverCharacteristics([BLEUUIDs.characteristicReadRequestToHistoricalDataUUID, BLEUUIDs.characteristicHistoricalDataUUID], for: service)
//                }
//            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
//        guard error == nil else {
//            print("Error discovering characteristics: \(error!.localizedDescription)")
//            return
//        }
//
//        if let characteristics = service.characteristics {
//            for characteristic in characteristics {
//                if characteristic.uuid == BLEUUIDs.characteristicReadRequestToHistoricalDataUUID {
//                    // Bereite den Befehl vor, um die Leseanforderung zu initiieren
//                    let cmdHistoryReadInit: [UInt8] = [0xa0, 0x00, 0x00]
//                    let data = Data(cmdHistoryReadInit)
//                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
//                }
//            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
//        if let error = error {
//            print("Failed to write to characteristic: \(error.localizedDescription)")
//            return
//        }
//        
//        if characteristic.uuid == BLEUUIDs.characteristicReadRequestToHistoricalDataUUID {
//            print("Initiated read request for historical data.")
//            // Jetzt die Charakteristik für historische Daten abfragen
//            if let service = peripheral.services?.first(where: {$0.uuid == BLEUUIDs.serviceHistoricalDataUUID}),
//               let historicalDataCharacteristic = service.characteristics?.first(where: {$0.uuid == BLEUUIDs.characteristicHistoricalDataUUID}) {
//                peripheral.readValue(for: historicalDataCharacteristic)
//            }
//        }
//    }
//
//    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        if let error = error {
//            print("Error reading characteristic: \(error.localizedDescription)")
//            return
//        }
//
//        if characteristic.uuid == BLEUUIDs.characteristicHistoricalDataUUID, let data = characteristic.value {
//            // Verarbeite die Daten
//            print("Historical data received: \(data)")
//            parseHistoricalData(data: data)
//        }
//    }
//
//    func parseHistoricalData(data: Data) {
//        // Deine Logik, um die Daten zu parsen und eventuell in CoreData zu speichern
//    }
//}
//
