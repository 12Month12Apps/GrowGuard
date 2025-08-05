//
//  UUIDs.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation
import CoreBluetooth
import Combine

let flowerCareServiceUUID = CBUUID(string: "0000fe95-0000-1000-8000-00805f9b34fb")
let dataServiceUUID = CBUUID(string: "00001204-0000-1000-8000-00805f9b34fb")
let historyServiceUUID = CBUUID(string: "00001206-0000-1000-8000-00805f9b34fb")

let deviceNameCharacteristicUUID = CBUUID(string: "00002a00-0000-1000-8000-00805f9b34fb")
let realTimeSensorValuesCharacteristicUUID = CBUUID(string: "00001a01-0000-1000-8000-00805f9b34fb")
let firmwareVersionCharacteristicUUID = CBUUID(string: "00001a02-0000-1000-8000-00805f9b34fb")
let deviceModeChangeCharacteristicUUID = CBUUID(string: "00001a00-0000-1000-8000-00805f9b34fb")
let historicalSensorValuesCharacteristicUUID = CBUUID(string: "00001a11-0000-1000-8000-00805f9b34fb")
let deviceTimeCharacteristicUUID = CBUUID(string: "00001a12-0000-1000-8000-00805f9b34fb")
let historyControlCharacteristicUUID = CBUUID(string: "00001a10-0000-1000-8000-00805f9b34fb")
let entryCountCharacteristicUUID = CBUUID(string: "00001a13-0000-1000-8000-00805f9b34fb")
let authenticationCharacteristicUUID = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
