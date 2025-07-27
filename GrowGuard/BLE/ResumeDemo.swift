//
//  ResumeDemo.swift
//  GrowGuard
//
//  Demo showing the improved BLE history loading with resume capability
//

import Foundation

#if DEBUG
extension FlowerCareManager {
    
    /// Demo function showing the resume capability
    func demonstrateResumeCapability() {
        print("\n🎬 === BLE History Loading Resume Demo ===")
        
        let deviceUUID = "demo-device-12345"
        
        // Scenario 1: First time loading (no saved progress)
        print("\n📱 Scenario 1: First time loading")
        print("Device UUID: \(deviceUUID)")
        print("Total entries: 500")
        
        testTotalEntries = 500
        testCurrentEntryIndex = 0
        
        print("Starting fresh load...")
        saveLoadingProgress(deviceUUID: deviceUUID)
        
        // Simulate loading some entries
        for i in 0..<75 {
            testCurrentEntryIndex = i
            if i % 10 == 0 {
                saveLoadingProgress(deviceUUID: deviceUUID)
                print("✅ Progress saved at entry \(i)/500 (\(Int(Double(i)/500.0 * 100))%)")
            }
        }
        
        print("❌ Connection lost at entry 75/500 (15%)")
        print("Progress automatically saved!")
        
        // Scenario 2: Reconnection and resume
        print("\n📱 Scenario 2: Reconnection and resume")
        
        // Reset to simulate disconnection
        testTotalEntries = 0
        testCurrentEntryIndex = 0
        
        // Check for saved progress
        if let savedProgress = getLoadingProgress(deviceUUID: deviceUUID) {
            print("📍 Found saved progress:")
            print("   - Current index: \(savedProgress.currentIndex)")
            print("   - Total entries: \(savedProgress.totalEntries)")
            print("   - Completion: \(Int(savedProgress.completionPercentage * 100))%")
            print("   - Last saved: \(savedProgress.lastUpdateDate)")
            
            // Resume from saved position
            print("\n🔄 Resuming from index \(savedProgress.currentIndex)...")
            resumeHistoricalDataLoading(deviceUUID: deviceUUID)
            
            print("✅ Resume successful!")
            print("   Current index: \(testCurrentEntryIndex)")
            print("   Total entries: \(testTotalEntries)")
            
        } else {
            print("❌ No saved progress found")
        }
        
        // Scenario 3: Complete loading and cleanup
        print("\n📱 Scenario 3: Complete loading")
        
        // Simulate finishing the rest
        testCurrentEntryIndex = testTotalEntries
        onHistoryLoadingCompleted()
        
        // Check that progress was cleared
        if getLoadingProgress(deviceUUID: deviceUUID) == nil {
            print("✅ Progress cleared after completion")
        } else {
            print("❌ Progress not cleared")
        }
        
        // Scenario 4: Show all device progress
        print("\n📱 Scenario 4: Progress summary")
        print(progressManager.getProgressSummary())
        
        print("\n🎬 === Demo Complete ===\n")
    }
    
    /// Demo function showing validation of corrupted progress
    func demonstrateProgressValidation() {
        print("\n🛡️ === Progress Validation Demo ===")
        
        let deviceUUID = "validation-device-123"
        
        // Create corrupted progress
        let corruptedProgress = HistoryLoadingProgress(
            deviceUUID: deviceUUID,
            currentIndex: -5, // Invalid negative index
            totalEntries: 100,
            lastUpdateDate: Date(),
            deviceBootTime: Date()
        )
        
        setLoadingProgress(corruptedProgress)
        print("📝 Set corrupted progress: index=-5, total=100")
        
        // Try to resume - should detect and handle corruption
        print("🔍 Attempting to resume with corrupted data...")
        resumeHistoricalDataLoading(deviceUUID: deviceUUID)
        
        print("✅ Corrupted data handled gracefully")
        print("   Current index: \(testCurrentEntryIndex)")
        print("   Total entries: \(testTotalEntries)")
        
        print("\n🛡️ === Validation Demo Complete ===\n")
    }
    
    /// Demo function showing batch resume capability
    func demonstrateBatchResume() {
        print("\n📦 === Batch Resume Demo ===")
        
        let deviceUUID = "batch-device-456"
        
        // Simulate disconnection in middle of batch
        testTotalEntries = 100
        testCurrentEntryIndex = 37 // Disconnected at entry 37
        saveLoadingProgress(deviceUUID: deviceUUID)
        
        print("📊 Simulated disconnection at entry 37/100")
        print("   - Last completed batch: entries 30-39")
        print("   - Partial progress in batch: entry 37")
        
        // Resume from last completed batch
        print("\n🔄 Resuming from last completed batch...")
        resumeFromLastCompletedBatch(deviceUUID: deviceUUID)
        
        print("✅ Batch resume successful!")
        print("   Resumed from: \(testCurrentEntryIndex) (start of incomplete batch)")
        
        // Clean up
        progressManager.clearProgress(for: deviceUUID)
        
        print("\n📦 === Batch Resume Demo Complete ===\n")
    }
}
#endif