//
//  DeviceConnection+PeripheralLink.swift
//  GrowGuard
//
//  BLEPeripheralLinkDelegate-Callbacks (Service/Characteristic Discovery,
//  eingehende Daten, Write-Bestätigungen, RSSI) und die Verarbeitung der
//  empfangenen Rohdaten über den SensorDataDecoder.
//

import Foundation
import CoreBluetooth

extension DeviceConnection: BLEPeripheralLinkDelegate {

    // MARK: - BLEPeripheralLinkDelegate

    /// Callback wenn Services entdeckt wurden
    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverServices serviceUUIDs: [CBUUID], error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Service discovery error for device \(deviceUUID): \(error.localizedDescription)")
            stateSubject.send(.error(error))
            return
        }

        // Prüfe ob Services gefunden wurden
        guard !serviceUUIDs.isEmpty else {
            AppLogger.ble.bleWarning("No services found for device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("Discovered \(serviceUUIDs.count) service(s) for device \(deviceUUID)")

        // Iteriere über alle gefundenen Services
        for serviceUUID in serviceUUIDs {
            AppLogger.ble.bleConnection("Found service: \(serviceUUID.uuidString)")

            // Starte Characteristic Discovery für jeden Service
            link.discoverCharacteristics(forService: serviceUUID)
        }
    }

    /// Callback wenn Characteristics für einen Service entdeckt wurden
    func peripheralLink(_ link: BLEPeripheralLink, didDiscoverCharacteristics characteristicUUIDs: [CBUUID], forService serviceUUID: CBUUID, error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Characteristic discovery error for device \(deviceUUID): \(error.localizedDescription)")
            stateSubject.send(.error(error))
            return
        }

        // Prüfe ob Characteristics gefunden wurden
        guard !characteristicUUIDs.isEmpty else {
            AppLogger.ble.bleWarning("No characteristics found for service \(serviceUUID.uuidString) on device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("Discovered \(characteristicUUIDs.count) characteristic(s) for service \(serviceUUID.uuidString) on device \(deviceUUID)")

        // Speichere alle gefundenen Characteristics
        for characteristicUUID in characteristicUUIDs {
            discoveredCharacteristics.insert(characteristicUUID)
            AppLogger.ble.bleConnection("Found characteristic: \(characteristicUUID.uuidString)")
        }

        // Prüfe ob wir auf Characteristics für History Resume warten
        if waitingForCharacteristicsForHistoryResume &&
           hasHistoryControlCharacteristic &&
           hasHistoryDataCharacteristic &&
           hasDeviceTimeCharacteristic {
            AppLogger.ble.info("✅ History characteristics discovered, ready to resume")
            waitingForCharacteristicsForHistoryResume = false

            // Resume history flow now that characteristics are available
            if autoStartHistoryFlowEnabled,
               isHistoryFlowActive && totalEntries > 0 && currentEntryIndex < totalEntries && isAuthenticated {
                AppLogger.ble.info("🔄 Resuming history flow now at entry \(self.currentEntryIndex)/\(self.totalEntries)")
                scheduler.schedule(after: 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.startHistoryDataFlow()
                }
            } else if !autoStartHistoryFlowEnabled {
                AppLogger.ble.info("⏭️ Auto history start disabled for device \(self.deviceUUID) - not resuming history flow")
            }
        }

        // CRITICAL FIX: Only start authentication when ALL required characteristics are found
        // This matches FlowerManager's behavior
        if !isAuthenticated && authenticationStep == 0 &&
           hasHistoryControlCharacteristic &&
           hasHistoryDataCharacteristic &&
           hasDeviceTimeCharacteristic {
            AppLogger.ble.bleConnection("✅ All required characteristics discovered for device \(deviceUUID), starting authentication")
            startAuthentication()
        } else if !isAuthenticated && authenticationStep == 0 {
            AppLogger.ble.bleWarning("⚠️ Not all characteristics found yet, waiting... (history control: \(hasHistoryControlCharacteristic), history data: \(hasHistoryDataCharacteristic), device time: \(hasDeviceTimeCharacteristic))")
        }
    }

    /// Callback wenn eine Characteristic updated wurde (neue Daten empfangen)
    func peripheralLink(_ link: BLEPeripheralLink, didUpdateValueFor characteristicUUID: CBUUID, value: Data?, error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Update value error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Prüfe ob wir Daten haben
        guard let value = value else {
            AppLogger.ble.bleWarning("No value in characteristic \(characteristicUUID.uuidString) for device \(deviceUUID)")
            return
        }

        // Handle Authentication Response wenn noch nicht authenticated
        if !isAuthenticated && characteristicUUID == authenticationCharacteristicUUID {
            handleAuthenticationResponse(value)
            return
        }

        // Verarbeite Daten nur wenn authenticated
        guard isAuthenticated else {
            AppLogger.ble.bleWarning("Received data but not authenticated yet for device \(deviceUUID)")
            return
        }

        // Verarbeite basierend auf Characteristic UUID
        switch characteristicUUID {
        case realTimeSensorValuesCharacteristicUUID:
            AppLogger.ble.bleData("📊 Received real-time sensor data for device \(deviceUUID)")
            processRealTimeSensorData(value)

        case firmwareVersionCharacteristicUUID:
            AppLogger.ble.bleData("🔋 Received firmware/battery data for device \(deviceUUID)")
            processFirmwareAndBattery(value)

        case deviceNameCharacteristicUUID:
            AppLogger.ble.bleData("📛 Received device name for device \(deviceUUID)")
            processDeviceName(value)

        case deviceTimeCharacteristicUUID:
            AppLogger.ble.bleData("⏱️ Received device time for device \(deviceUUID)")
            processDeviceTime(value)

        case historicalSensorValuesCharacteristicUUID:
            AppLogger.ble.bleData("📦 Received historical sensor data for device \(deviceUUID)")
            processHistoryData(value)

        default:
            AppLogger.ble.bleConnection("Received data for characteristic \(characteristicUUID.uuidString) on device \(deviceUUID)")
        }
    }

    /// Callback wenn Daten an eine Characteristic geschrieben wurden
    func peripheralLink(_ link: BLEPeripheralLink, didWriteValueFor characteristicUUID: CBUUID, error: Error?) {
        AppLogger.ble.bleConnection("didWriteValueFor called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Write value error for device \(deviceUUID): \(error.localizedDescription)")
            liveDataReadPending = false
            return
        }

        // Nach bestätigtem Mode Change (0xA01F) den Realtime-Wert lesen —
        // FlowerCare liefert Live-Daten nur per Read (wie FlowerCareManager:
        // kurze Pause, damit der Sensor die Messung aktualisiert)
        if characteristicUUID == deviceModeChangeCharacteristicUUID && liveDataReadPending {
            liveDataReadPending = false
            scheduler.schedule(after: 0.25) { [weak self] in
                guard let self = self,
                      let peripheral = self.peripheral,
                      peripheral.state == .connected,
                      self.discoveredCharacteristics.contains(realTimeSensorValuesCharacteristicUUID) else {
                    AppLogger.ble.bleError("❌ Cannot read live sensor data: device disconnected or characteristic missing")
                    return
                }

                AppLogger.ble.bleData("📊 Reading fresh sensor data for device \(self.deviceUUID)")
                peripheral.readValue(forCharacteristic: realTimeSensorValuesCharacteristicUUID)
            }
        }
    }

    /// Callback wenn RSSI gelesen wurde
    func peripheralLink(_ link: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?) {
        if let error = error {
            AppLogger.ble.bleWarning("RSSI read error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        AppLogger.ble.bleConnection("📶 RSSI for device \(deviceUUID): \(rssi) dBm")

        rssiSubject.send(rssi)

        if rssi < -70 {
            AppLogger.ble.bleWarning("⚠️ Weak signal for device \(deviceUUID): \(rssi) dBm")
        }
    }

    // MARK: - Data Processing

    /// Verarbeitet Real-Time Sensor-Daten
    /// - Parameter data: Die rohen Sensor-Daten vom Gerät
    private func processRealTimeSensorData(_ data: Data) {
        // Dekodiere Sensor-Daten
        guard let sensorData = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: deviceUUID) else {
            AppLogger.ble.bleError("Failed to decode real-time sensor data for device \(deviceUUID)")
            return
        }

        AppLogger.sensor.info("✅ Decoded sensor data for device \(self.deviceUUID): temp=\(sensorData.temperature)°C, moisture=\(sensorData.moisture)%, brightness=\(sensorData.brightness)lux, conductivity=\(sensorData.conductivity)µS/cm")

        // Sende Sensor-Daten via Publisher
        sensorDataSubject.send(sensorData)
    }

    /// Verarbeitet Firmware und Battery Daten
    /// - Parameter data: Die rohen Firmware/Battery Daten vom Gerät
    private func processFirmwareAndBattery(_ data: Data) {
        guard let (battery, firmware) = decoder.decodeFirmwareAndBattery(data: data) else {
            AppLogger.ble.bleError("Failed to decode firmware/battery data for device \(deviceUUID)")
            return
        }

        AppLogger.sensor.info("🔋 Device \(self.deviceUUID) battery: \(battery)%, firmware: \(firmware)")

        deviceInfoSubject.send(DeviceInfo(battery: Int(battery), firmware: firmware))
    }

    /// Verarbeitet Device Name Daten
    /// - Parameter data: Die rohen Device Name Daten vom Gerät
    private func processDeviceName(_ data: Data) {
        if let deviceName = String(data: data, encoding: .utf8) {
            AppLogger.ble.bleConnection("📛 Device name for \(deviceUUID): \(deviceName)")
            // TODO: Update Device Info in Database (kommt später)
        }
    }

    /// Verarbeitet Device Time Daten
    /// - Parameter data: Die rohen Device Time Daten vom Gerät
    private func processDeviceTime(_ data: Data) {
        guard data.count >= 4 else {
            AppLogger.ble.bleError("Device time data too short for device \(deviceUUID)")
            return
        }

        // Extract seconds since device boot
        let secondsSinceBoot = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)

        // Calculate boot time by subtracting secondsSinceBoot from current time
        let now = Date()
        deviceBootTime = now.addingTimeInterval(-Double(secondsSinceBoot))

        AppLogger.ble.info("⏱️ Device \(self.deviceUUID) uptime: \(secondsSinceBoot) seconds")
        AppLogger.ble.info("🕰️ Device \(self.deviceUUID) estimated boot time: \(self.deviceBootTime?.description ?? "unknown")")

        // Pass this information to the decoder for timestamp calculations
        decoder.setDeviceBootTime(bootTime: deviceBootTime, secondsSinceBoot: secondsSinceBoot)
    }

    /// Verarbeitet Historical Sensor Data
    /// - Parameter data: Die rohen Historical Data vom Gerät
    private func processHistoryData(_ data: Data) {
        // Drop in-flight responses that arrive after the flow was cancelled
        // or completed (mirrors the isCancelled check in FlowerCareManager)
        guard isHistoryFlowActive else {
            AppLogger.ble.info("❌ Ignoring history data after flow ended for device \(self.deviceUUID)")
            return
        }

        // Antwort angekommen → Entry-Timeout entschärfen
        entryResponseTimeoutTask?.cancel()
        entryResponseTimeoutTask = nil

        AppLogger.ble.bleData("📦 Received history data: \(data.count) bytes for device \(deviceUUID)")

        // Check if this is metadata or an actual history entry
        if data.count == 16 && currentEntryIndex == 0 && totalEntries == 0 {
            // This is likely metadata about history (entry count)
            if let (count, _) = decoder.decodeHistoryMetadata(data: data) {
                totalEntries = count
                AppLogger.ble.info("📊 Total historical entries from metadata: \(self.totalEntries) for device \(self.deviceUUID)")

                // Publish initial progress
                historyProgressSubject.send((0, totalEntries))

                // If there are entries, start fetching them
                if totalEntries > 0 {
                    currentEntryIndex = 0
                    fetchHistoricalDataEntry(index: currentEntryIndex)
                } else {
                    AppLogger.ble.info("ℹ️ No historical entries available for device \(self.deviceUUID)")
                    cleanupHistoryFlow()
                }
            } else {
                // Failed to decode metadata
                AppLogger.ble.bleError("❌ Failed to decode history metadata for device \(self.deviceUUID)")
                cleanupHistoryFlow()
            }
        } else {
            // This is an actual history entry
            if let historicalData = decoder.decodeHistoricalSensorData(data: data, deviceUUID: deviceUUID) {
                AppLogger.ble.info("📊 Decoded history entry \(self.currentEntryIndex) for device \(self.deviceUUID): temp=\(historicalData.temperature)°C, moisture=\(historicalData.moisture)%, conductivity=\(historicalData.conductivity)µS/cm")

                // Erfolg → Retry-Zähler für den nächsten Entry zurücksetzen
                entryRetryCount = 0

                // Send historical data via publisher
                historicalDataSubject.send(historicalData)

                // Update progress
                let nextIndex = currentEntryIndex + 1
                currentEntryIndex = nextIndex

                // Publish progress update
                historyProgressSubject.send((nextIndex, totalEntries))

                if nextIndex < totalEntries {
                    // Optimized batch processing with minimal delays
                    let batchSize = 150 // Larger batches for better performance
                    if nextIndex % batchSize == 0 {
                        AppLogger.ble.bleData("Completed batch of \(batchSize) for device \(deviceUUID). Brief pause...")
                        // Very short pause to avoid overwhelming the device
                        let batchTask = scheduler.schedule(after: 0.05) { [weak self] in
                            self?.fetchHistoricalDataEntry(index: nextIndex)
                        }
                        self.historyFlowTasks.append(batchTask)
                    } else {
                        // Minimal delay between individual entries
                        let nextEntryTask = scheduler.schedule(after: 0.02) { [weak self] in
                            self?.fetchHistoricalDataEntry(index: nextIndex)
                        }
                        self.historyFlowTasks.append(nextEntryTask)
                    }
                } else {
                    AppLogger.ble.info("✅ All historical data fetched successfully for device \(self.deviceUUID) - \(self.totalEntries) entries loaded")

                    // Notify UI that historical loading is complete
                    NotificationCenter.default.post(name: NSNotification.Name("HistoricalDataLoadingCompleted"), object: self.deviceUUID)

                    cleanupHistoryFlow()
                }
            } else {
                AppLogger.ble.bleError("⚠️ Failed to decode history entry \(currentEntryIndex) for device \(deviceUUID)")
                // Garbage-Frame: gleicher Pfad wie "keine Antwort" —
                // begrenzte Retries, dann Skip mit Budget
                handleEntryFailure(index: currentEntryIndex)
            }
        }
    }
}
