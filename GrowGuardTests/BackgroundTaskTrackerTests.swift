//
//  BackgroundTaskTrackerTests.swift
//  GrowGuardTests
//
//  Debug tracking: every background event lands in the execution history
//  labeled with what triggered it, so a silent push is distinguishable
//  from a BGTask run and a failed wake read is visible at all.
//

import Testing
import Foundation
@testable import GrowGuard

@Suite
struct BackgroundTaskTrackerTests {

    let defaults = UserDefaults(suiteName: "BackgroundTaskTrackerTests-\(UUID().uuidString)")!

    private func makeTracker() -> BackgroundTaskTracker {
        BackgroundTaskTracker(defaults: defaults)
    }

    @Test("Silent push is counted and appears in the execution history with its armed sensor count")
    func pushAppearsInHistory() {
        let tracker = makeTracker()

        tracker.recordPushReceived(armedSensors: 2)

        #expect(tracker.pushReceivedCount == 1)
        #expect(tracker.lastPushReceivedDate != nil)
        let entry = tracker.executionHistory.first
        #expect(entry?.type == .silentPush)
        #expect(entry?.trigger == .silentPush)
        #expect(entry?.detail == "Armed 2 sensor(s)")
    }

    @Test("BLE wake reads carry the arm trigger and are counted separately from BGTask runs")
    func wakeReadCarriesTrigger() {
        let tracker = makeTracker()

        tracker.recordWakeRead(trigger: .silentPush, outcome: .saved, duration: 3.2)
        tracker.recordWakeRead(trigger: .enterBackground, outcome: .timedOut, duration: 9.0)

        #expect(tracker.wakeReadSuccessCount == 1)
        #expect(tracker.wakeReadFailureCount == 1)
        #expect(tracker.refreshTaskCount == 0, "A wake read is not a BGAppRefreshTask run")

        let history = tracker.executionHistory
        #expect(history.map(\.type) == [.bleWake, .bleWake])
        #expect(history.map(\.trigger) == [.enterBackground, .silentPush])
        #expect(history.map(\.success) == [false, true])
        #expect(history.first?.detail == WakeReadOutcome.timedOut.rawValue)
    }

    @Test("A wake read that also fetched history says how many entries")
    func wakeReadReportsHistoryEntries() {
        let tracker = makeTracker()

        tracker.recordWakeRead(trigger: .silentPush, outcome: .saved, duration: 4, historyEntries: 2)
        tracker.recordWakeRead(trigger: .silentPush, outcome: .saved, duration: 3)

        #expect(tracker.executionHistory.map(\.detail) == ["Saved", "Saved · 2 history entries"])
    }

    @Test("Wake after an app relaunch has no known trigger")
    func relaunchWakeHasNoTrigger() {
        let tracker = makeTracker()

        tracker.recordWakeRead(trigger: nil, outcome: .saved, duration: 1)

        let entry = tracker.executionHistory.first
        #expect(entry?.trigger == nil)
        #expect(entry?.triggerLabel == "Relaunch (trigger unknown)")
    }

    @Test("BGTask runs are recorded with their trigger")
    func taskRunsRecorded() {
        let tracker = makeTracker()

        tracker.recordRefreshTaskRun(armedSensors: 1, expired: false)
        tracker.recordProcessingTaskRun(duration: 12, expired: true)

        #expect(tracker.refreshTaskCount == 1)
        #expect(tracker.processingTaskCount == 1)
        let history = tracker.executionHistory
        #expect(history.map(\.type) == [.processing, .refresh])
        #expect(history.map(\.trigger) == [.processingTask, .refreshTask])
        #expect(history.first?.success == false)
        #expect(history.first?.detail == "Expired before finishing")
        #expect(history.last?.success == true)
    }

    @Test("A refresh task that expires while arming is recorded as failed")
    func expiredRefreshRecordedAsFailure() {
        let tracker = makeTracker()

        tracker.recordRefreshTaskRun(armedSensors: 1, expired: true)

        let entry = tracker.executionHistory.first
        #expect(entry?.success == false, "Must match setTaskCompleted(success: false)")
        #expect(entry?.detail == "Expired while arming 1 sensor(s)")
    }

    @Test("History written by older builds still decodes (no trigger/success/detail keys)")
    func legacyHistoryDecodes() throws {
        let legacy = """
        [{"type":"Refresh","date":811281026.1,"failedDevices":0,
          "id":"7B6A5D4C-A68C-4F61-952D-918DCEF6B200","dataPoints":1,
          "duration":0,"successfulDevices":1}]
        """
        defaults.set(Data(legacy.utf8), forKey: "background_execution_history")

        let history = makeTracker().executionHistory

        #expect(history.count == 1)
        #expect(history.first?.type == .refresh)
        #expect(history.first?.trigger == nil)
        #expect(history.first?.triggerLabel == "Unknown (legacy entry)")
    }

    @Test("Reset clears the wake read counters")
    func resetClearsWakeCounters() {
        let tracker = makeTracker()
        tracker.recordWakeRead(trigger: .refreshTask, outcome: .saved, duration: 1)
        tracker.recordPushReceived(armedSensors: 1)

        tracker.resetAll()

        #expect(tracker.wakeReadSuccessCount == 0)
        #expect(tracker.lastWakeReadDate == nil)
        #expect(tracker.pushReceivedCount == 0)
        #expect(tracker.executionHistory.isEmpty)
    }
}
