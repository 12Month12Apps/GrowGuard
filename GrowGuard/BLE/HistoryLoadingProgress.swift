//
//  HistoryLoadingProgress.swift
//  GrowGuard
//
//  Data structures for BLE history loading resume functionality
//

import Foundation

// MARK: - History Loading Progress

struct HistoryLoadingProgress: Codable, Equatable {
    let deviceUUID: String
    let currentIndex: Int
    let totalEntries: Int
    let lastUpdateDate: Date
    let deviceBootTime: Date?
    
    var isValid: Bool {
        return currentIndex >= 0 && currentIndex <= totalEntries && totalEntries > 0
    }
    
    var completionPercentage: Double {
        guard totalEntries > 0 else { return 0.0 }
        return Double(currentIndex) / Double(totalEntries)
    }
}

// MARK: - Data Gap Detection

struct DataGap {
    let startDate: Date
    let endDate: Date
    let missingIndexes: [Int]
    let estimatedEntryCount: Int
    
    var timeRange: TimeInterval {
        return endDate.timeIntervalSince(startDate)
    }
}

// MARK: - Loading Plan

struct LoadingPlan {
    let deviceUUID: String
    let totalEntriesToLoad: Int
    let indexesToLoad: [Int]
    let estimatedTimeRemaining: TimeInterval
    let strategy: LoadingStrategy
    
    enum LoadingStrategy {
        case fullLoad           // Load everything from 0
        case resumeFromIndex    // Resume from specific index
        case fillGaps          // Load only missing entries
        case newestFirst       // Load newest entries first
    }
}

// MARK: - Progress Persistence Manager

class HistoryProgressManager {
    private let userDefaults = UserDefaults.standard
    private let progressKey = "HistoryLoadingProgress"
    
    func saveProgress(_ progress: HistoryLoadingProgress) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(progress)
            var allProgress = loadAllProgress()
            allProgress[progress.deviceUUID] = progress
            
            let allData = try encoder.encode(allProgress)
            userDefaults.set(allData, forKey: progressKey)
            print("📁 Saved loading progress for device \(progress.deviceUUID): \(progress.currentIndex)/\(progress.totalEntries)")
        } catch {
            print("❌ Failed to save loading progress: \(error)")
        }
    }
    
    func loadProgress(for deviceUUID: String) -> HistoryLoadingProgress? {
        let allProgress = loadAllProgress()
        let progress = allProgress[deviceUUID]
        
        // Validate progress age (expire after 24 hours)
        if let progress = progress {
            let ageHours = Date().timeIntervalSince(progress.lastUpdateDate) / 3600
            if ageHours > 24 {
                print("⏰ Loading progress for \(deviceUUID) expired (\(ageHours) hours old)")
                clearProgress(for: deviceUUID)
                return nil
            }
        }
        
        return progress
    }
    
    func clearProgress(for deviceUUID: String) {
        var allProgress = loadAllProgress()
        allProgress.removeValue(forKey: deviceUUID)
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(allProgress)
            userDefaults.set(data, forKey: progressKey)
            print("🗑️ Cleared loading progress for device \(deviceUUID)")
        } catch {
            print("❌ Failed to clear loading progress: \(error)")
        }
    }
    
    func clearAllProgress() {
        userDefaults.removeObject(forKey: progressKey)
        print("🗑️ Cleared all loading progress")
    }
    
    private func loadAllProgress() -> [String: HistoryLoadingProgress] {
        guard let data = userDefaults.data(forKey: progressKey) else {
            return [:]
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode([String: HistoryLoadingProgress].self, from: data)
        } catch {
            print("❌ Failed to load loading progress: \(error)")
            return [:]
        }
    }
    
    // MARK: - Statistics
    
    func getProgressSummary() -> String {
        let allProgress = loadAllProgress()
        let deviceCount = allProgress.count
        let inProgressCount = allProgress.values.filter { $0.currentIndex < $0.totalEntries }.count
        
        return "Progress tracked for \(deviceCount) devices, \(inProgressCount) in progress"
    }
}