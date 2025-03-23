//
//  HistoricData.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

struct HistoricalSensorData {
    var timestamp: UInt32
    var temperature: Double
    var brightness: UInt32
    var moisture: UInt8
    var conductivity: UInt16
    var date: Date
}
