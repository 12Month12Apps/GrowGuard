//
//  Item.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import Foundation
import SwiftData
import CoreBluetooth

@Model
final class FlowerDevice {
    var added: Date
    var lastUpdate: Date
    var uuid: String
    var name: String
    var sensorData: [SensorData]
    
    init(added: Date, lastUpdate: Date, peripheral: CBPeripheral) {
        self.added = added
        self.lastUpdate = lastUpdate
        self.uuid = peripheral.identifier.uuidString
        self.name = peripheral.name ?? ""
        self.sensorData = []
    }
}
