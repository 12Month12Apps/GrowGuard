//
//  Extensions.swift
//  GrowGuard
//
//  Created by veitprogl on 07.10.24.
//

import Foundation
import SwiftUI
import Charts

extension Array where Element == SensorDataDTO {
    func groupedByDay<T: Comparable & Numeric>(by keyPath: KeyPath<SensorDataDTO, T>) -> [(date: Date, minValue: T, maxValue: T)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: self) { data in
            calendar.startOfDay(for: data.date)
        }
        
        return grouped.map { (date, dataPoints) in
            let minValue = dataPoints.map { $0[keyPath: keyPath] }.min()!
            let maxValue = dataPoints.map { $0[keyPath: keyPath] }.max()!
            return (date, minValue, maxValue)
        }.sorted { $0.date < $1.date }
    }
}

// MARK: - Accessibility

extension SensorDataChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let dateStringConverter: ((Date) -> (String)) = { date in
            DateFormatter.short().string(from: date)
        }
        
        let groupedData = data.groupedByDay(by: \.moisture)
        
        let min = groupedData.map(\.minValue).min() ?? 0
        let max = groupedData.map(\.maxValue).max() ?? 0
        
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "Date",
            categoryOrder: groupedData.map { dateStringConverter($0.date) }
        )

        let yAxis = AXNumericDataAxisDescriptor(
            title: "Moisture",
            range: Double(min)...Double(max),
            gridlinePositions: []
        ) { value in "Average: \(Int(value)) %"
        }

        let series = AXDataSeriesDescriptor(
            name: "Sensor Data",
            isContinuous: false,
            dataPoints: groupedData.map {
                .init(x: dateStringConverter($0.date),
                      y: Double($0.maxValue),
                      label: "\(dateStringConverter($0.date)): Min: \($0.minValue) %, Max: \($0.maxValue) %")
            }
        )

        return AXChartDescriptor(
            title: "Moisture Range",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

extension DateFormatter {
    static func short() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }
}
