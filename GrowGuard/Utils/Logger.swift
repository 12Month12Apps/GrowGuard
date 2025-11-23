//
//  Logger.swift
//  GrowGuard
//
//  Created for BLE debugging and beta testing support
//

import Foundation
import OSLog
import UIKit

/// Centralized logging system for GrowGuard
/// Supports log file export for beta testing and debugging
struct AppLogger {
    
    // MARK: - Log Categories
    
    /// BLE communication and device management
    static let ble = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "BLE")
    
    /// Database operations and Core Data
    static let database = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "Database")
    
    /// UI and user interactions
    static let ui = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "UI")
    
    /// Sensor data processing and validation
    static let sensor = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "Sensor")
    
    /// General app lifecycle and errors
    static let general = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "General")

    /// Network/API communication
    static let network = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.growguard", category: "Network")
    
    // MARK: - Log Export for Beta Testing
    
    /// Exports recent log entries for the specified time period
    /// - Parameter hours: Number of hours of logs to export (default: 24)
    /// - Returns: URL to the exported log file, or nil if export failed
    static func exportLogs(lastHours: Int = 24) async -> URL? {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let oneHourAgo = Date().addingTimeInterval(-Double(lastHours) * 3600)
            
            let position = store.position(date: oneHourAgo)
            let entries = try store.getEntries(at: position)
            
            // Filter for our app's logs only
            let appLogs = entries.compactMap { entry in
                return entry as? OSLogEntryLog
            }.filter { logEntry in
                return logEntry.subsystem == Bundle.main.bundleIdentifier ?? "com.growguard"
            }
            
            // Create log export file
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            
            let fileName = "GrowGuard_Logs_\(timestamp).txt"
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let logFileURL = documentsPath.appendingPathComponent(fileName)
            
            // Build log content
            let logContent = buildLogContent(from: appLogs)
            
            try logContent.write(to: logFileURL, atomically: true, encoding: .utf8)
            
            AppLogger.general.info("Log export successful: \(logFileURL.path)")
            return logFileURL
            
        } catch {
            AppLogger.general.error("Failed to export logs: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Exports logs and prepares them for sharing via email/AirDrop
    /// - Parameter hours: Number of hours of logs to export
    /// - Returns: URL to the log file ready for sharing
    static func exportLogsForSharing(lastHours: Int = 24) async -> URL? {
        guard let logFileURL = await exportLogs(lastHours: lastHours) else {
            return nil
        }
        
        // Add device info header
        do {
            let deviceInfo = buildDeviceInfoHeader()
            let existingContent = try String(contentsOf: logFileURL)
            let fullContent = deviceInfo + "\n\n" + existingContent
            
            try fullContent.write(to: logFileURL, atomically: true, encoding: .utf8)
            return logFileURL
        } catch {
            AppLogger.general.error("Failed to add device info to logs: \(error.localizedDescription)")
            return logFileURL // Return original file even if we couldn't add device info
        }
    }
    
    // MARK: - Private Helpers
    
    private static func buildLogContent(from logEntries: [OSLogEntryLog]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        var content = "GrowGuard Debug Logs\n"
        content += "Generated: \(formatter.string(from: Date()))\n"
        content += "Total Entries: \(logEntries.count)\n"
        content += String(repeating: "=", count: 50) + "\n\n"
        
        for entry in logEntries {
            let timestamp = formatter.string(from: entry.date)
            let level = logLevelString(from: entry.level)
            let category = entry.category
            let message = entry.composedMessage
            
            content += "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        }
        
        return content
    }
    
    private static func buildDeviceInfoHeader() -> String {
        let device = UIDevice.current
        var info = "DEVICE INFORMATION\n"
        info += String(repeating: "=", count: 30) + "\n"
        info += "App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")\n"
        info += "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")\n"
        info += "Device: \(device.model)\n"
        info += "iOS Version: \(device.systemVersion)\n"
        info += "Device Name: \(device.name)\n"
        info += "System Uptime: \(ProcessInfo.processInfo.systemUptime) seconds\n"
        info += "Export Date: \(Date())\n"
        
        return info
    }
    
    private static func logLevelString(from level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined:
            return "UNDEFINED"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .notice:
            return "NOTICE"
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        @unknown default:
            return "UNKNOWN"
        }
    }
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log BLE connection events
    func bleConnection(_ message: String) {
        self.info("🔗 Connection: \(message)")
    }
    
    /// Log BLE data transmission
    func bleData(_ message: String) {
        self.debug("📡 Data: \(message)")
    }
    
    /// Log BLE errors
    func bleError(_ message: String) {
        self.error("❌ BLE Error: \(message)")
    }
    
    /// Log BLE warnings
    func bleWarning(_ message: String) {
        self.warning("⚠️ BLE Warning: \(message)")
    }
    
    /// Log sensor data processing
    func sensorData(_ message: String) {
        self.info("📊 Sensor: \(message)")
    }
    
    /// Log database operations
    func database(_ message: String) {
        self.debug("💾 Database: \(message)")
    }
}
