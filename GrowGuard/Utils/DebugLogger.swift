import Foundation

struct DebugLogger {
    static func log(_ message: String, level: LogLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        // Only log in debug builds, and only important messages to reduce debugger overhead
        guard level.rawValue >= LogLevel.warning.rawValue else { return }
        
        let filename = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.debugTimestamp.string(from: Date())
        print("[\(timestamp)] \(level.emoji) \(filename):\(line) \(function) - \(message)")
        #endif
    }
}

enum LogLevel: Int {
    case verbose = 0
    case info = 1
    case warning = 2
    case error = 3
    
    var emoji: String {
        switch self {
        case .verbose: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

extension DateFormatter {
    static let debugTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}