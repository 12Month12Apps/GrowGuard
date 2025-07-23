//
//  Chart.swift
//  GrowGuard
//
//  Created by Veit Progl on 31.08.24.
//

import SwiftUI
import Charts

enum ChartType {
    case water
    case bars
}

struct SensorDataChart<T: Comparable & Numeric>: View {
    var isOverview: Bool
    var componet: Calendar.Component

    @Binding var data: [SensorDataDTO]
    var keyPath: KeyPath<SensorDataDTO, T>

    var title: String
    var dataType: String
    var selectedChartType: ChartType
    var minRange: Int
    var maxRange: Int

    @State private var barWidth = 10.0
    @State private var chartColor: Color = .red
    @State private var graphColor: Color = .cyan
    @State private var currentWeekIndex = 0

    // Computed property that recalculates groupedData whenever data changes
    private var groupedData: [(date: Date, minValue: Double, maxValue: Double)] {
        let grouped = data.groupedByDay(by: keyPath)
        return grouped.map { ($0.date, Double(truncating: $0.minValue as! NSNumber), Double(truncating: $0.maxValue as! NSNumber)) }
    }

    var body: some View {
        if isOverview {
            chart(for: currentWeekIndex)
        } else {
            Section {
                VStack {
                    header(for: currentWeekIndex, current: groupedData.last?.maxValue ?? 0)
                    if groupedData.isEmpty {
                        Text("No data available")
                            .foregroundColor(.gray)
                            .frame(height: 250)
                    } else {
                        chart(for: currentWeekIndex)
                            .frame(height: 250)
                    }
                }
                .onAppear {
                    currentWeekIndex = numberOfWeeks - 1
                }
            }
        }
    }

    private var numberOfWeeks: Int {
        let start = startOfWeek(for: groupedData.first?.date ?? Date())
        let end = startOfWeek(for: groupedData.last?.date ?? Date())
        let totalDays = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return max((totalDays / 7) + 1, 1)  // Ensure at least one week is shown
    }

    private func chart(for weekIndex: Int) -> some View {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: startOfWeek(for: groupedData.first?.date ?? Date()))!
        let endDate = calendar.date(byAdding: .day, value: 6, to: startDate)!

        let filteredData = groupedData.filter { $0.date >= startDate && $0.date <= endDate }

        if filteredData.isEmpty {
            return AnyView(
                Text("No data available for this week")
                    .foregroundColor(.gray)
                    .frame(height: 250)
            )
        } else {
            return AnyView(
                Chart(filteredData, id: \.date) { dataPoint in
                    RectangleMark(
                        xStart: .value("Start", startDate, unit: componet),
                        xEnd: .value("End", endDate, unit: componet),
                        yStart: .value("Low", minRange),
                        yEnd: .value("High", maxRange)
                    )
                    .foregroundStyle(Color.gray.opacity(0.1))
                    
//                    if selectedChartType == .water {
//                        BarMark(
//                            x: .value("Date", dataPoint.date, unit: componet),
//                            yStart: .value("\(title) Min", dataPoint.minValue),
//                            yEnd: .value("\(title) Max", dataPoint.maxValue + 2),
//                            width: .fixed(isOverview ? 8 : 10)
//                        )
//                        .clipShape(Capsule())
//                        .foregroundStyle(chartColor.gradient)
//
//                        LineMark(
//                            x: .value("Date", dataPoint.date, unit: componet),
//                            y: .value("\(title) \(dataType)", dataPoint.maxValue)
//                        )
//                        .interpolationMethod(.cardinal)
//                        .foregroundStyle(graphColor.gradient)
//                        .symbol(Circle().strokeBorder(lineWidth: barWidth))
                        
                        PointMark(x: .value("Date", dataPoint.date, unit: componet),
                                  y: .value("\(title) \(dataType)", dataPoint.maxValue))
                            .foregroundStyle(chartColor.gradient)
//                    } else if selectedChartType == .bars {
//                        BarMark(
//                            x: .value("Date", dataPoint.date, unit: componet),
//                            y: .value(title, dataPoint.maxValue),
//                            width: .fixed(12)
//                        )
//                        .foregroundStyle(chartColor.gradient)
//                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisTick()
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisTick()
                        AxisGridLine()
                        AxisValueLabel {
                            if let intValue = value.as(Double.self) {
                                Text("\(intValue, specifier: "%.0f")\(dataType)")
                            }
                        }
                    }
                }
                .accessibilityChartDescriptor(self)
            )
        }
    }

    private func startOfWeek(for date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
    }
    
    private func endOfWeek(for date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 6, to: startOfWeek(for: date))!
    }

    private func header(for weekIndex: Int, current: Double) -> some View {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: startOfWeek(for: groupedData.first?.date ?? Date()))!
        let endDate = calendar.date(byAdding: .day, value: 6, to: startDate)!
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        return HStack {
            if currentWeekIndex > 0 {
                Button(action: {
                    if currentWeekIndex > 0 {
                        currentWeekIndex -= 1
                    }
                }) {
                    Image(systemName: "arrowshape.backward.circle")
                }
                .buttonStyle(.bordered)
                .frame(width: 50)
            } else {
                Spacer().frame(width: 50)
            }
            
            Spacer()
            
            VStack {
                Text("\(title) Range")
                    .font(.system(.title, design: .rounded))
                    .foregroundColor(.primary)
                Text("\(dateFormatter.string(from: startDate)) - \(dateFormatter.string(from: endDate))")
                Text("Current Value: \(String(current))")
            }
            .fontWeight(.semibold)
            
            Spacer()
            
            if currentWeekIndex < numberOfWeeks - 1 {
                Button(action: {
                    if currentWeekIndex < numberOfWeeks - 1 {
                        currentWeekIndex += 1
                    }
                }) {
                    Image(systemName: "arrowshape.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .frame(width: 50)
            } else {
                Spacer().frame(width: 50)
            }
        }
    }
}
