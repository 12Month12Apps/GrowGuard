import Foundation

@MainActor
class SensorDataManager: ObservableObject {
    static let shared = SensorDataManager()
    
    @Published var isLoading = false
    @Published var currentWeek: Date = Date()
    
    // Cache for loaded sensor data by device UUID and week
    private var cache: [String: [String: [SensorDataDTO]]] = [:] // [deviceUUID: [weekKey: [SensorDataDTO]]]
    private let repositoryManager = RepositoryManager.shared
    
    private let calendar = Calendar.current
    private let cacheTimeout: TimeInterval = 300 // 5 minutes cache timeout
    private var cacheTimestamps: [String: Date] = [:]
    
    private init() {}
    
    // MARK: - Public API
    
    /// Get sensor data for a specific week (loads from cache or fetches if needed)
    func getSensorData(for deviceUUID: String, week: Date) async throws -> [SensorDataDTO] {
        let weekKey = weekKey(for: week)
        let cacheKey = "\(deviceUUID)-\(weekKey)"
        
        // Check cache first
        if let cachedData = getCachedData(deviceUUID: deviceUUID, weekKey: weekKey) {
            print("📊 SensorDataManager: Using cached data for week \(weekKey)")
            return cachedData
        }
        
        // Load from repository
        print("📊 SensorDataManager: Loading data for week \(weekKey)")
        isLoading = true
        defer { isLoading = false }
        
        do {
            let (startDate, endDate) = weekBounds(for: week)
            let sensorData = try await repositoryManager.sensorDataRepository.getSensorDataInDateRange(
                for: deviceUUID,
                startDate: startDate,
                endDate: endDate
            )
            
            // Cache the data
            cacheData(sensorData, deviceUUID: deviceUUID, weekKey: weekKey)
            cacheTimestamps[cacheKey] = Date()
            
            return sensorData
        } catch {
            print("❌ SensorDataManager: Failed to load data for week \(weekKey): \(error)")
            throw error
        }
    }
    
    /// Get current week's data
    func getCurrentWeekData(for deviceUUID: String) async throws -> [SensorDataDTO] {
        return try await getSensorData(for: deviceUUID, week: currentWeek)
    }
    
    /// Navigate to previous week
    func goToPreviousWeek(for deviceUUID: String) async throws -> [SensorDataDTO] {
        currentWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek) ?? currentWeek
        return try await getSensorData(for: deviceUUID, week: currentWeek)
    }
    
    /// Navigate to next week
    func goToNextWeek(for deviceUUID: String) async throws -> [SensorDataDTO] {
        currentWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? currentWeek
        return try await getSensorData(for: deviceUUID, week: currentWeek)
    }
    
    /// Preload adjacent weeks for smoother navigation
    func preloadAdjacentWeeks(for deviceUUID: String) {
        Task {
            let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek) ?? currentWeek
            let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? currentWeek
            
            // Preload in background without updating UI
            try? await getSensorData(for: deviceUUID, week: previousWeek)
            try? await getSensorData(for: deviceUUID, week: nextWeek)
        }
    }
    
    /// Clear cache for a specific device
    func clearCache(for deviceUUID: String) {
        cache[deviceUUID] = nil
        
        // Remove timestamps for this device
        let keysToRemove = cacheTimestamps.keys.filter { $0.hasPrefix(deviceUUID) }
        keysToRemove.forEach { cacheTimestamps[$0] = nil }
        
        print("🗑️ SensorDataManager: Cleared cache for device \(deviceUUID)")
    }
    
    /// Clear all cached data
    func clearAllCache() {
        cache.removeAll()
        cacheTimestamps.removeAll()
        print("🗑️ SensorDataManager: Cleared all cache")
    }
    
    // MARK: - Private Helpers
    
    private func weekKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-ww" // Year-Week format
        return formatter.string(from: date)
    }
    
    private func weekBounds(for date: Date) -> (start: Date, end: Date) {
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek) ?? date
        
        // Set to end of day for end date
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endOfWeek) ?? endOfWeek
        
        return (startOfWeek, endOfDay)
    }
    
    private func getCachedData(deviceUUID: String, weekKey: String) -> [SensorDataDTO]? {
        let cacheKey = "\(deviceUUID)-\(weekKey)"
        
        // Check if cache is still valid
        if let timestamp = cacheTimestamps[cacheKey],
           Date().timeIntervalSince(timestamp) > cacheTimeout {
            // Cache expired, remove it
            cache[deviceUUID]?[weekKey] = nil
            cacheTimestamps[cacheKey] = nil
            return nil
        }
        
        return cache[deviceUUID]?[weekKey]
    }
    
    private func cacheData(_ data: [SensorDataDTO], deviceUUID: String, weekKey: String) {
        if cache[deviceUUID] == nil {
            cache[deviceUUID] = [:]
        }
        cache[deviceUUID]?[weekKey] = data
    }
    
    // MARK: - Cache Statistics
    
    var cacheInfo: String {
        let totalDevices = cache.keys.count
        let totalWeeks = cache.values.flatMap { $0.keys }.count
        let totalRecords = cache.values.flatMap { $0.values }.flatMap { $0 }.count
        
        return "Cached: \(totalDevices) devices, \(totalWeeks) weeks, \(totalRecords) records"
    }
}

// MARK: - Repository Extension

extension SensorDataRepository {
    func getSensorDataInDateRange(for deviceUUID: String, startDate: Date, endDate: Date) async throws -> [SensorDataDTO] {
        // This method should be implemented in CoreDataSensorDataRepository
        // For now, we'll use the existing method and filter
        let allData = try await getSensorData(for: deviceUUID, limit: nil)
        
        return allData.filter { sensorData in
            sensorData.date >= startDate && sensorData.date <= endDate
        }.sorted { $0.date < $1.date }
    }
}