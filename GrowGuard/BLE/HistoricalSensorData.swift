//
//  HistoricData.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation

struct HistoricalSensorData {
    let deviceUUID: String
    let timestamp: UInt32
    let temperature: Double
    let brightness: UInt32
    let moisture: UInt8
    let conductivity: UInt16
    let date: Date
}
