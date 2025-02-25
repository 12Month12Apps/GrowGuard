//
//  FlowerManager.swift
//  GrowGuard
//
//  Created by Veit Progl on 02.06.24.
//

import Foundation
import CoreBluetooth
import Combine

class FlowerCareManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var realTimeSensorValuesCharacteristic: CBCharacteristic?
    var historyControlCharacteristic: CBCharacteristic?
    var historyDataCharacteristic: CBCharacteristic?
    var deviceTimeCharacteristic: CBCharacteristic?
    var entryCountCharacteristic: CBCharacteristic?
    var isConnected = false
    
    private var isScanning = false
    private var device: FlowerDevice?
    private var totalEntries: Int = 0
    private var currentEntryIndex: Int = 0
    
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()

    private let decoder = SensorDataDecoder()

    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        return sensorDataSubject.eraseToAnyPublisher()
    }
    
    var historicalDataPublisher: AnyPublisher<HistoricalSensorData, Never> {
        return historicalDataSubject.eraseToAnyPublisher()
    }
    
    static var shared = FlowerCareManager()

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning(device: FlowerDevice) {
        self.device = device
        guard let centralManager = centralManager else { return }
        if !isScanning && centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            isScanning = true
            print("Scanning started")
        }
    }

    func stopScanning() {
        guard let centralManager = centralManager else { return }
        if isScanning {
            centralManager.stopScan()
            isScanning = false
            print("Scanning stopped")
        }
    }
    
    func connectToKnownDevice(device: FlowerDevice) {
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [UUID(uuidString: device.uuid)!])
        if let peripheral = peripherals.first {
            discoveredPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
            print("Connecting to known device...")
        } else {
            print("Known device not found, starting scan...")
            startScanning(device: device) // example method call
        }
    }
    
    func disconnect() {
        guard let centralManager = centralManager, let peripheral = discoveredPeripheral else { return }

        centralManager.cancelPeripheralConnection(peripheral)
        print("Disconnecting from peripheral...")

        // Reset properties
        discoveredPeripheral = nil
        realTimeSensorValuesCharacteristic = nil
        historyControlCharacteristic = nil
        historyDataCharacteristic = nil
        deviceTimeCharacteristic = nil
        entryCountCharacteristic = nil

        isScanning = false
        device = nil
        totalEntries = 0
        currentEntryIndex = 0
        isConnected = false
    }
    
    func reloadScanning() {
        guard let centralManager = centralManager else { return }
        if centralManager.state == .poweredOn {
            if isScanning {
                centralManager.stopScan()
                print("Scanning stopped for reload")
            }
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            isScanning = true
            print("Scanning restarted")
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            print("Bluetooth is not available.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.identifier.uuidString == device?.uuid {
            centralManager.stopScan()
            discoveredPeripheral = peripheral
            discoveredPeripheral?.delegate = self
            centralManager.connect(discoveredPeripheral!, options: nil)
            print("Flower Care Sensor found. Connecting...")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([dataServiceUUID, historyServiceUUID])
        self.isConnected = true
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
                case historyControlCharacteristicUUID:
                    historyControlCharacteristic = characteristic
                    fetchEntryCount()
                case historicalSensorValuesCharacteristicUUID:
                    historyDataCharacteristic = characteristic
                case deviceTimeCharacteristicUUID:
                    deviceTimeCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                case entryCountCharacteristicUUID:
                    entryCountCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
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

        if characteristic.uuid == historyControlCharacteristicUUID {
            if currentEntryIndex < totalEntries {
                fetchHistoricalDataEntry(index: currentEntryIndex)
            }
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
            case historicalSensorValuesCharacteristicUUID:
                decodeHistoryData(data: value)
            case entryCountCharacteristicUUID:
                decodeEntryCount(data: value)
            default:
                break
            }
        }
    }

    private func decodeEntryCount(data: Data) {
       if let count = decoder.decodeEntryCount(data: data) {
           totalEntries = count
           print("Total historical entries: \(totalEntries)")

           if totalEntries > 0 {
               currentEntryIndex = 0
               fetchHistoricalDataEntry(index: currentEntryIndex)
           } else {
               print("No historical entries available.")
           }
       }
   }
    
    private func decodeRealTimeSensorValues(data: Data) {
        if let sensorData = decoder.decodeRealTimeSensorValues(data: data, device: device) {
            sensorDataSubject.send(sensorData)
        }
    }

    private func decodeFirmwareAndBattery(data: Data) {
        decoder.decodeFirmwareAndBattery(data: data)
    }

    private func decodeDeviceName(data: Data) {
        decoder.decodeDeviceName(data: data)
    }

    private func decodeDeviceTime(data: Data) {
        decoder.decodeDeviceTime(data: data)
    }

    private func decodeHistoryData(data: Data) {
        if let historicalData = decoder.decodeHistoricalSensorData(data: data) {
            historicalDataSubject.send(historicalData)
            // Fetch the next entry
            currentEntryIndex += 1
            if currentEntryIndex < totalEntries {
                fetchHistoricalDataEntry(index: currentEntryIndex)
            }
        }
    }

    private func fetchEntryCount() {
        guard let historyControlCharacteristic = historyControlCharacteristic else {
            print("History control characteristic not found.")
            return
        }

        let command: [UInt8] = [0xa0]
        let commandData = Data(command)
        discoveredPeripheral?.writeValue(commandData, for: historyControlCharacteristic, type: .withResponse)
    }

    private func fetchHistoricalDataEntry(index: Int) {
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])
        if let historyControlCharacteristic = historyControlCharacteristic {
            discoveredPeripheral?.writeValue(entryAddress, for: historyControlCharacteristic, type: .withResponse)
        }
    }
}
