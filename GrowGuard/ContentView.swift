//
//  ContentView.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import SwiftUI
import SwiftData

import CoreBluetooth

let flowerCareServiceUUID = CBUUID(string: "0000fe95-0000-1000-8000-00805f9b34fb")
let dataServiceUUID = CBUUID(string: "00001204-0000-1000-8000-00805f9b34fb")
let historyServiceUUID = CBUUID(string: "00001206-0000-1000-8000-00805f9b34fb")

let deviceNameCharacteristicUUID = CBUUID(string: "00002a00-0000-1000-8000-00805f9b34fb")
let realTimeSensorValuesCharacteristicUUID = CBUUID(string: "00001a01-0000-1000-8000-00805f9b34fb")
let firmwareVersionCharacteristicUUID = CBUUID(string: "00001a02-0000-1000-8000-00805f9b34fb")
let deviceModeChangeCharacteristicUUID = CBUUID(string: "00001a00-0000-1000-8000-00805f9b34fb")
let historicalSensorValuesCharacteristicUUID = CBUUID(string: "00001a11-0000-1000-8000-00805f9b34fb")
let deviceTimeCharacteristicUUID = CBUUID(string: "00001a12-0000-1000-8000-00805f9b34fb")

class FlowerCareManager2: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var realTimeSensorValuesCharacteristic: CBCharacteristic?

    override init() {
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
        if discoveredPeripheral != peripheral {
            discoveredPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([dataServiceUUID, historyServiceUUID])
    }

    // MARK: - CBPeripheralDelegate Methods
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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
                case historicalSensorValuesCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                case deviceTimeCharacteristicUUID:
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

        if characteristic.uuid == deviceModeChangeCharacteristicUUID {
            if let realTimeCharacteristic = realTimeSensorValuesCharacteristic {
                peripheral.readValue(for: realTimeCharacteristic)
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
            case deviceNameCharacteristicUUID:
                let deviceName = String(data: value, encoding: .utf8)
                print("Device Name: \(deviceName ?? "Unknown")")
            case realTimeSensorValuesCharacteristicUUID:
                // Parse the real-time sensor values
                print("Real-time Sensor Values: \(value)")
                decodeRealTimeSensorValues(data: value)
            case firmwareVersionCharacteristicUUID:
                // Parse firmware version and battery level
                print("Firmware Version and Battery Level: \(value)")
            case historicalSensorValuesCharacteristicUUID:
                // Parse historical sensor values
                print("Historical Sensor Values: \(value)")
            case deviceTimeCharacteristicUUID:
                // Parse device time
                print("Device Time: \(value)")
            default:
                break
            }
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
    }
}




struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
 
    var manager = FlowerCareManager2()
    
    var body: some View {
        NavigationSplitView {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                    } label: {
                        Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                    }
                }
                .onDelete(perform: deleteItems)
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
    }

    private func addItem() {
//        flowerCareManager.requestDataUpdate()
//        flowerCareManager.requestDataFromSensor()
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
