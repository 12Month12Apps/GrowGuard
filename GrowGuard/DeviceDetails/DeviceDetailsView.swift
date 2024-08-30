//
//  DeviceDetailsView.swift
//  GrowGuard
//
//  Created by Veit Progl on 09.06.24.
//

import Foundation
import SwiftUI
import Charts

struct SensorDataChart: View {
    var isOverview: Bool
    var componet: Calendar.Component

    @Binding var data: [SensorData]

    @State private var barWidth = 10.0
    @State private var chartColor: Color = .red
    @State private var graphColor: Color = .cyan

    var body: some View {
        if isOverview {
            chart
        } else {
//            Picker("Grouping Option", selection: $viewModel.groupingOption) {
//                Text("Day").tag(Calendar.Component.day)
//                Text("Week").tag(Calendar.Component.weekOfYear)
//                Text("Month").tag(Calendar.Component.month)
//            }
//            .pickerStyle(SegmentedPickerStyle())
//            .padding()
            
            Section(header: header) {
                chart
            }
//            .navigationBarTitle("Sensor Data", displayMode: .inline)
        }
    }

    private var chart: some View {
        let groupedData = data.groupedByDay()
        
        return Chart(groupedData, id: \.date) { dataPoint in
            RectangleMark(
                xStart: .value("Start", data.first?.date ?? Date(), unit: componet),
                xEnd: .value("End", data.last?.date ?? Date(), unit: componet),
               yStart: .value("Low", 40),
               yEnd: .value("High", 60)
           )
            .foregroundStyle(Color.gray.opacity(0.05))
            
            Plot {
                BarMark(
                    x: .value("Date", dataPoint.date, unit: componet),
                    yStart: .value("Moisture Min", dataPoint.minMoisture),
                    yEnd: .value("Moisture Max", dataPoint.maxMoisture),
                    width: .fixed(isOverview ? 8 : barWidth)
                )
                .clipShape(Capsule())
                .foregroundStyle(
                                (dataPoint.maxMoisture - dataPoint.minMoisture > 10) ? Color.blue.gradient :
                                ((dataPoint.minMoisture >= 40 && dataPoint.maxMoisture <= 60) ? Color.green.gradient : chartColor.gradient)
                            )            }
//            .accessibilityLabel(dataPoint.date, formatter: DateFormatter.short())
            .accessibilityValue("\(dataPoint.minMoisture) to \(dataPoint.maxMoisture) %")
            .accessibilityHidden(isOverview)
            
            LineMark(
                x: .value("Date", dataPoint.date, unit: componet),
                y: .value("Moisture %", dataPoint.maxMoisture)
            )
            .interpolationMethod(.cardinal)
//            .lineStyle(StrokeStyle(lineWidth: lineWidth))
            .foregroundStyle(graphColor.gradient)
            .symbol(Circle().strokeBorder(lineWidth: barWidth))
//            .symbolSize(showSymbols ? 60 : 0)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: componet)) { _ in
                AxisTick()
                AxisGridLine()
                if componet == .weekOfYear {
                    AxisValueLabel(format: .dateTime.week())
                } else if componet == .month {
                    AxisValueLabel(format: .dateTime.month())
                } else {
                    AxisValueLabel(format: .dateTime.day().month())
                }
            }
        }
        .accessibilityChartDescriptor(self)
        .chartYAxis {
                AxisMarks { value in
                    AxisTick()
                    AxisGridLine()
                    AxisValueLabel {
                        if let intValue = value.as(Double.self) {
                            Text("\(intValue, specifier: "%.0f")%")
                        }
                    }
                }
            }
        .frame(height: isOverview ? 200 : 400)
    }

    private var header: some View {
        VStack(alignment: .leading) {
            Text("Moisture Range")
            Text("Sensor Data")
                .font(.system(.title, design: .rounded))
                .foregroundColor(.primary)
        }
        .fontWeight(.semibold)
    }
}

// MARK: - Accessibility

extension SensorDataChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let dateStringConverter: ((Date) -> (String)) = { date in
            DateFormatter.short().string(from: date)
        }
        
        let groupedData = data.groupedByDay()
        
        let min = groupedData.map(\.minMoisture).min() ?? 0
        let max = groupedData.map(\.maxMoisture).max() ?? 0
        
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
                      y: Double($0.maxMoisture),
                      label: "\(dateStringConverter($0.date)): Min: \($0.minMoisture) %, Max: \($0.maxMoisture) %")
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



struct DeviceDetailsView: View {
    @State var viewModel: DeviceDetailsViewModel

    init(device: FlowerDevice) {
        self.viewModel = DeviceDetailsViewModel(device: device)
    }
    
    var body: some View {
        List {
            TextField("Device Name", text: $viewModel.device.name)
//            .font(.headline)
            Text("Added: ") + Text(viewModel.device.added, format: .dateTime)
            Text("Last Update: ") + Text(viewModel.device.lastUpdate, format: .dateTime)
            
            SensorDataChart(isOverview: false,
                            componet: viewModel.groupingOption,
                            data: $viewModel.device.sensorData)
            
            Button {
                viewModel.delete()
            } label: {
                Text("Delete")
            }

        }.onAppear {
            self.viewModel.loadDetails()
        }
        .navigationTitle(viewModel.device.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    viewModel.reloadSensor()

                }, label: {
                    Image(systemName: "arrow.clockwise")
                        .animation(.smooth)
                })
            }
        }
    }
}

extension Array where Element == SensorData {
    func groupedByDay() -> [(date: Date, minMoisture: UInt8, maxMoisture: UInt8)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: self) { calendar.startOfDay(for: $0.date) }
        
        return grouped.map { (date, dataPoints) in
            let minMoisture = dataPoints.map { $0.moisture }.min() ?? 0
            let maxMoisture = dataPoints.map { $0.moisture }.max() ?? 0
            let adjustedMaxMoisture = minMoisture == maxMoisture ? minMoisture + 2 : maxMoisture
            return (date, minMoisture, adjustedMaxMoisture)
        }.sorted { $0.date < $1.date }
    }
}
