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
            VStack(spacing: 12) {
                // Current value display
                if let currentValue = groupedData.last?.maxValue {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                                .fontWeight(.semibold)

                            HStack(spacing: 4) {
                                Text("Current:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(String(format: "%.1f", currentValue))\(dataType)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(getColorForValue(currentValue))
                            }
                        }

                        Spacer()

                        // Range indicator
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Optimal Range")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(minRange) - \(maxRange)\(dataType)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.tertiarySystemGroupedBackground))
                    .cornerRadius(12)
                }

                // Chart
                if groupedData.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("No data available")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                } else {
                    chart(for: currentWeekIndex)
                        .frame(height: 250)
                }
            }
            .padding()
            .background(Color(.tertiarySystemGroupedBackground).opacity(0.5))
            .cornerRadius(16)
            .onAppear {
                currentWeekIndex = numberOfWeeks - 1
            }
        }
    }

    private func getColorForValue(_ value: Double) -> Color {
        let minD = Double(minRange)
        let maxD = Double(maxRange)

        if value < minD {
            return .orange
        } else if value > maxD {
            return .red
        } else {
            return .green
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
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("No data available for this week")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 250)
            )
        } else {
            return AnyView(
                Chart(filteredData, id: \.date) { dataPoint in
                    // Optimal range background
                    RectangleMark(
                        xStart: .value("Start", startDate, unit: componet),
                        xEnd: .value("End", endDate, unit: componet),
                        yStart: .value("Low", minRange),
                        yEnd: .value("High", maxRange)
                    )
                    .foregroundStyle(Color.green.opacity(0.1))

                    if selectedChartType == .water {
                        // Line chart with gradient fill
                        AreaMark(
                            x: .value("Date", dataPoint.date, unit: componet),
                            y: .value("\(title) \(dataType)", dataPoint.maxValue)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [chartColor.opacity(0.3), chartColor.opacity(0.05)]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", dataPoint.date, unit: componet),
                            y: .value("\(title) \(dataType)", dataPoint.maxValue)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                        PointMark(
                            x: .value("Date", dataPoint.date, unit: componet),
                            y: .value("\(title) \(dataType)", dataPoint.maxValue)
                        )
                        .foregroundStyle(chartColor)
                        .symbolSize(60)
                    } else if selectedChartType == .bars {
                        BarMark(
                            x: .value("Date", dataPoint.date, unit: componet),
                            y: .value(title, dataPoint.maxValue),
                            width: .fixed(isOverview ? 8 : 12)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [chartColor, chartColor.opacity(0.7)]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel(format: .dateTime.day().month())
                            .font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisTick(stroke: StrokeStyle(lineWidth: 1))
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let intValue = value.as(Double.self) {
                                Text("\(intValue, specifier: "%.0f")")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color(.systemBackground).opacity(0.5))
                        .cornerRadius(8)
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
