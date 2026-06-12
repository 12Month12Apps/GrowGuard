//
//  DeviceConnection+HistoryFlow.swift
//  GrowGuard
//
//  Historical Data Flow: Mode-Init → Device Time → Entry Count → Entries.
//  Reliability-Verhalten (BLE-Reliability.md): Per-Entry-Timeout mit
//  begrenzten Retries und Skip-Budget, suspendHistoryFlow() für Resume
//  nach Reconnect vs. cleanupHistoryFlow() für den endgültigen Abschluss.
//

import Foundation
import CoreBluetooth

extension DeviceConnection {

    /// Startet den Historical Data Flow
    /// Liest alle verfügbaren historischen Einträge vom Gerät
    func startHistoryDataFlow() {
        // Check if we're resuming after a reconnect
        let isResumingHistory = totalEntries > 0 && currentEntryIndex < totalEntries

        // Prevent multiple concurrent NEW history flows (but allow resume)
        if isHistoryFlowActive && !isResumingHistory {
            AppLogger.ble.info("⚠️ History flow already active for device \(self.deviceUUID), ignoring request")
            return
        }

        // Prüfe ob authentifiziert
        guard isAuthenticated else {
            AppLogger.ble.bleWarning("Cannot start history flow - device \(deviceUUID) not authenticated")
            return
        }

        // Prüfe ob Peripheral verbunden ist
        guard let peripheral = peripheral, peripheral.state == .connected else {
            AppLogger.ble.bleError("Cannot start history flow - device \(deviceUUID) not connected")
            return
        }

        if isResumingHistory {
            AppLogger.ble.info("🔄 Resuming history data flow at entry \(self.currentEntryIndex)/\(self.totalEntries) for device: \(self.deviceUUID)")
        } else {
            AppLogger.ble.info("🔄 Starting history data flow for device: \(self.deviceUUID)")
        }

        isHistoryFlowActive = true

        // Start connection quality monitoring (like FlowerManager)
        startConnectionQualityMonitoring()

        // Add overall timeout for history flow (10 minutes max)
        let historyTimeoutTask = scheduler.schedule(after: 600.0) { [weak self] in
            guard let self = self, self.isHistoryFlowActive else { return }
            AppLogger.ble.bleError("⏰ History flow timeout for device \(self.deviceUUID) - taking too long, aborting")
            self.cleanupHistoryFlow()
        }
        self.historyFlowTasks.append(historyTimeoutTask)

        // If resuming, we need to refresh device time before continuing
        if isResumingHistory {
            AppLogger.ble.info("⏭️ Resuming history at entry \(self.currentEntryIndex), re-initializing history mode first")
        } else {
            AppLogger.ble.info("🔄 Starting history data flow for device: \(self.deviceUUID)")
        }

        // Step 1: Send 0xa00000 to switch to history mode (required even when resuming after reconnect)
        guard hasHistoryControlCharacteristic else {
            AppLogger.ble.bleError("Cannot start history flow: history control characteristic not found for device \(deviceUUID)")
            isHistoryFlowActive = false
            return
        }

        AppLogger.ble.bleData("Step 1: Setting history mode (0xa00000) for device \(deviceUUID)")
        let modeCommand: [UInt8] = [0xa0, 0x00, 0x00]
        let modeData = Data(modeCommand)
        peripheral.writeValue(modeData, forCharacteristic: historyControlCharacteristicUUID, type: .withResponse)

        // Step 2: Read device time
        let step2Task = scheduler.schedule(after: 0.15) { [weak self] in
            guard let self = self,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected else {
                AppLogger.ble.bleError("Device \(self?.deviceUUID ?? "unknown") disconnected before step 2")
                self?.suspendHistoryFlow()
                return
            }

            AppLogger.ble.bleData("Step 2: Reading device time for device \(self.deviceUUID)")
            if self.hasDeviceTimeCharacteristic {
                peripheral.readValue(forCharacteristic: deviceTimeCharacteristicUUID)
            }

            // If resuming, skip to fetching the current entry
            if isResumingHistory {
                // Longer delay for more stable resume (like FlowerManager: 0.2s)
                let resumeTask = self.scheduler.schedule(after: 0.2) { [weak self] in
                    guard let self = self,
                          let peripheral = self.peripheral,
                          peripheral.state == .connected else {
                        AppLogger.ble.bleError("Device \(self?.deviceUUID ?? "unknown") disconnected before resume")
                        self?.suspendHistoryFlow()
                        return
                    }
                    _ = peripheral
                    AppLogger.ble.info("📍 Device time refreshed, resuming at entry \(self.currentEntryIndex)/\(self.totalEntries)")
                    self.fetchHistoricalDataEntry(index: self.currentEntryIndex)
                }
                self.historyFlowTasks.append(resumeTask)
                return
            }

            // Step 3: Get entry count (only for new flow)
            let step3Task = self.scheduler.schedule(after: 0.1) { [weak self] in
                guard let self = self,
                      let peripheral = self.peripheral,
                      peripheral.state == .connected else {
                    AppLogger.ble.bleError("Device \(self?.deviceUUID ?? "unknown") disconnected before step 3")
                    self?.suspendHistoryFlow()
                    return
                }

                AppLogger.ble.bleData("Step 3: Getting entry count (0x3c command) for device \(self.deviceUUID)")
                let entryCountCommand: [UInt8] = [0x3c]  // Command to get entry count
                peripheral.writeValue(Data(entryCountCommand), forCharacteristic: historyControlCharacteristicUUID, type: .withResponse)

                // After sending the command, read the history data characteristic
                let step4Task = self.scheduler.schedule(after: 0.1) { [weak self] in
                    guard let self = self,
                          let peripheral = self.peripheral,
                          peripheral.state == .connected else {
                        AppLogger.ble.bleError("Device \(self?.deviceUUID ?? "unknown") disconnected before step 4")
                        self?.suspendHistoryFlow()
                        return
                    }

                    AppLogger.ble.bleData("Step 4: Reading history data characteristic for device \(self.deviceUUID)")
                    if self.hasHistoryDataCharacteristic {
                        peripheral.readValue(forCharacteristic: historicalSensorValuesCharacteristicUUID)

                        // Add timeout for metadata response
                        let metadataTimeoutTask = self.scheduler.schedule(after: 10.0) { [weak self] in
                            guard let self = self, self.totalEntries == 0 && self.isHistoryFlowActive else { return }
                            AppLogger.ble.bleError("⏰ Metadata timeout for device \(self.deviceUUID) - no response after 10 seconds")
                            self.cleanupHistoryFlow()
                        }
                        self.historyFlowTasks.append(metadataTimeoutTask)
                    }
                }
                self.historyFlowTasks.append(step4Task)
            }
            self.historyFlowTasks.append(step3Task)
        }
        historyFlowTasks.append(step2Task)
    }

    /// Holt einen einzelnen Historical Data Entry vom Gerät
    /// - Parameter index: Der Index des gewünschten Eintrags
    func fetchHistoricalDataEntry(index: Int) {
        // Check if operation has been cancelled or flow is not active
        guard isHistoryFlowActive else {
            AppLogger.ble.info("❌ History data loading was cancelled or flow inactive for device \(self.deviceUUID)")
            return
        }

        guard let peripheral = peripheral,
              peripheral.state == .connected else {
            // Disconnect mitten im Fetch: Fortschritt behalten, der Pool
            // reconnected und resumed an genau diesem Index
            AppLogger.ble.bleError("Cannot fetch history entry: device \(deviceUUID) disconnected, suspending for resume")
            suspendHistoryFlow()
            return
        }

        guard hasHistoryControlCharacteristic,
              hasHistoryDataCharacteristic else {
            AppLogger.ble.bleError("Cannot fetch history entry: characteristics unavailable for device \(deviceUUID)")
            suspendHistoryFlow()
            return
        }

        AppLogger.ble.bleData("Fetching history entry \(index) of \(totalEntries) for device \(deviceUUID)")

        // Format index correctly: 0xa1 + 2-byte index in little endian
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])

        // Write address to history control characteristic
        peripheral.writeValue(entryAddress, forCharacteristic: historyControlCharacteristicUUID, type: .withResponse)

        // Minimal delay to give the device time to respond
        let readTask = scheduler.schedule(after: 0.02) { [weak self] in
            guard let self = self, self.isHistoryFlowActive else { return }
            guard let peripheral = self.peripheral,
                  peripheral.state == .connected,
                  self.hasHistoryDataCharacteristic else {
                AppLogger.ble.bleError("Device \(self.deviceUUID) disconnected before reading data, suspending for resume")
                self.suspendHistoryFlow()
                return
            }

            peripheral.readValue(forCharacteristic: historicalSensorValuesCharacteristicUUID)
        }
        historyFlowTasks.append(readTask)

        // Antwort-Timeout: stummer Sensor → Retry, dann Skip
        entryResponseTimeoutTask?.cancel()
        entryResponseTimeoutTask = scheduler.schedule(after: entryResponseTimeout) { [weak self] in
            guard let self = self,
                  self.isHistoryFlowActive,
                  self.currentEntryIndex == index,
                  self.peripheral?.state == .connected else { return }
            AppLogger.ble.bleWarning("⏰ No response for history entry \(index) on device \(self.deviceUUID)")
            self.handleEntryFailure(index: index)
        }
    }

    /// Gemeinsame Behandlung für fehlgeschlagene Entries (keine Antwort oder
    /// Garbage-Frame): begrenzte Retries, dann Skip mit Budget
    func handleEntryFailure(index: Int) {
        entryResponseTimeoutTask?.cancel()
        entryResponseTimeoutTask = nil

        if entryRetryCount < maxRetriesPerEntry {
            entryRetryCount += 1
            AppLogger.ble.info("🔁 Retrying history entry \(index) (attempt \(self.entryRetryCount)/\(self.maxRetriesPerEntry)) for device \(self.deviceUUID)")
            let retryTask = scheduler.schedule(after: 0.1) { [weak self] in
                self?.fetchHistoricalDataEntry(index: index)
            }
            historyFlowTasks.append(retryTask)
            return
        }

        // Retries aufgebraucht → Entry überspringen
        entryRetryCount = 0
        skippedEntryCount += 1
        AppLogger.ble.bleWarning("⏭️ Skipping history entry \(index) for device \(self.deviceUUID) (skipped so far: \(self.skippedEntryCount))")

        guard skippedEntryCount <= maxSkippedEntries else {
            AppLogger.ble.bleError("⛔️ Skip budget exceeded (\(self.skippedEntryCount)/\(self.maxSkippedEntries)) for device \(self.deviceUUID) - aborting sync")
            cleanupHistoryFlow()
            stateSubject.send(.error(ConnectionError.tooManyCorruptEntries))
            return
        }

        let nextIndex = index + 1
        currentEntryIndex = nextIndex
        historyProgressSubject.send((nextIndex, totalEntries))

        if nextIndex < totalEntries {
            let nextTask = scheduler.schedule(after: 0.1) { [weak self] in
                self?.fetchHistoricalDataEntry(index: nextIndex)
            }
            historyFlowTasks.append(nextTask)
        } else {
            AppLogger.ble.info("✅ History sync finished for device \(self.deviceUUID) (last entry skipped, \(self.skippedEntryCount) skipped total)")
            NotificationCenter.default.post(name: NSNotification.Name("HistoricalDataLoadingCompleted"), object: deviceUUID)
            cleanupHistoryFlow()
        }
    }

    /// Pausiert den History Flow für einen Resume nach Reconnect:
    /// laufende Tasks stoppen, Fortschritt (totalEntries/currentEntryIndex)
    /// BEHALTEN. Gegenstück: cleanupHistoryFlow() setzt alles zurück.
    func suspendHistoryFlow() {
        for task in historyFlowTasks {
            task.cancel()
        }
        historyFlowTasks.removeAll()
        entryResponseTimeoutTask?.cancel()
        entryResponseTimeoutTask = nil
        stopConnectionQualityMonitoring()
    }

    /// Räumt den Historical Data Flow auf und beendet ihn endgültig
    /// (Abschluss, User-Abbruch, globaler Timeout, Loop-Guard).
    /// Für Disconnects mit Resume-Absicht stattdessen suspendHistoryFlow().
    func cleanupHistoryFlow() {
        AppLogger.ble.info("🧹 Cleaning up history flow for device \(self.deviceUUID)")
        isHistoryFlowActive = false

        // Cancel all pending scheduled steps
        for task in historyFlowTasks {
            task.cancel()
        }
        historyFlowTasks.removeAll()
        entryResponseTimeoutTask?.cancel()
        entryResponseTimeoutTask = nil

        // Stop connection monitoring
        stopConnectionQualityMonitoring()

        // Reset history state to allow fresh start
        totalEntries = 0
        currentEntryIndex = 0
        deviceBootTime = nil
        entryRetryCount = 0
        lastSyncSkippedEntries = skippedEntryCount
        skippedEntryCount = 0

        AppLogger.ble.info("🧹 History flow cleanup complete for device \(self.deviceUUID) - state reset")
    }

    // MARK: - Connection Quality Monitoring

    /// Startet das Connection Quality Monitoring während History Flow
    /// Prüft alle 5 Sekunden die Verbindungsqualität via RSSI
    private func startConnectionQualityMonitoring() {
        stopConnectionQualityMonitoring()

        connectionMonitorTask = scheduler.scheduleRepeating(every: 5.0) { [weak self] in
            guard let self = self,
                  self.totalEntries > 0,
                  self.currentEntryIndex < self.totalEntries,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected else {
                self?.stopConnectionQualityMonitoring()
                return
            }

            AppLogger.ble.bleConnection("📡 Checking connection quality for device \(self.deviceUUID)")
            peripheral.readRSSI()
        }
    }

    /// Stoppt das Connection Quality Monitoring
    private func stopConnectionQualityMonitoring() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
    }
}
