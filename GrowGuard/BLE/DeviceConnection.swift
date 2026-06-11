//
//  DeviceConnection.swift
//  GrowGuard
//
//  Created by ConnectionPool Implementation
//  Verantwortlich für GENAU EINE BLE-Verbindung zu einem Sensor
//
//  Phase 3 (BLE-Testing-Strategy.md): spricht mit dem BLEPeripheralLink-Seam
//  statt direkt mit CBPeripheral und nutzt einen injizierbaren BLEScheduler
//  statt Timer/DispatchQueue — Produktion verhält sich identisch
//  (Default-Argumente), Tests können Zeit und Gerät deterministisch steuern.
//

import Foundation
import CoreBluetooth
import Combine
import OSLog

/// Verwaltet die BLE-Verbindung zu einem einzelnen Flower Care Sensor
/// Diese Klasse kapselt alle BLE-Operationen für ein spezifisches Gerät
/// und stellt isolierte Publisher für Sensor-Daten bereit
class DeviceConnection: NSObject, BLEPeripheralLinkDelegate {

    // MARK: - Connection State

    /// Repräsentiert alle möglichen Verbindungszustände
    enum ConnectionState: Equatable {
        case disconnected           // Keine Verbindung
        case connecting             // Verbindungsaufbau läuft
        case connected              // Verbunden, aber noch nicht authentifiziert
        case authenticated          // Verbunden und authentifiziert, bereit für Daten
        case error(Error)           // Fehler aufgetreten

        // Equatable Conformance für Error-Fall
        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.authenticated, .authenticated):
                return true
            case (.error(let lhsError), .error(let rhsError)):
                return lhsError.localizedDescription == rhsError.localizedDescription
            default:
                return false
            }
        }
    }

    // MARK: - Public Properties

    /// UUID des Geräts - eindeutige Identifikation des Sensors
    /// Read-only, wird beim Init gesetzt und kann nicht geändert werden
    private(set) var deviceUUID: String

    // MARK: - Private Properties

    /// Das Peripheral hinter dem Transport-Seam
    /// Wird gesetzt sobald das Gerät gefunden wurde
    private(set) var peripheral: BLEPeripheralLink?

    /// Scheduler für alle zeitgesteuerten Abläufe (Timer-Ersatz)
    private let scheduler: BLEScheduler

    /// Aktueller Authentifizierungs-Status
    /// true = Gerät ist authentifiziert und bereit für Datenübertragung
    private var isAuthenticated = false

    /// Aktueller Authentication Step (0 = nicht gestartet, 1 = Challenge gesendet, 2 = Final Key gesendet)
    private var authenticationStep: Int = 0

    /// Erwartete Response für Authentication Validation
    private var expectedResponse: Data?

    /// Alle bisher entdeckten Characteristic-UUIDs
    private var discoveredCharacteristics: Set<CBUUID> = []

    /// Decoder für Sensor-Daten
    /// Wandelt rohe BLE-Bytes in strukturierte Sensor-Daten um
    private let decoder = SensorDataDecoder()

    // MARK: - Discovered Characteristics (für schnellen Zugriff)

    private var hasHistoryControlCharacteristic: Bool {
        discoveredCharacteristics.contains(historyControlCharacteristicUUID)
    }

    private var hasHistoryDataCharacteristic: Bool {
        discoveredCharacteristics.contains(historicalSensorValuesCharacteristicUUID)
    }

    private var hasDeviceTimeCharacteristic: Bool {
        discoveredCharacteristics.contains(deviceTimeCharacteristicUUID)
    }

    private var hasAuthenticationCharacteristic: Bool {
        discoveredCharacteristics.contains(authenticationCharacteristicUUID)
    }

    // MARK: - Historical Data Properties

    /// Gesamtanzahl der verfügbaren Historical Entries auf dem Gerät
    private var totalEntries: Int = 0

    /// Aktueller Index beim Abrufen von Historical Data
    private var currentEntryIndex: Int = 0

    /// Flag ob der Historical Data Flow aktiv ist
    private var isHistoryFlowActive: Bool = false

    /// Device Boot Time für Timestamp-Berechnungen
    private var deviceBootTime: Date?

    /// Laufende zeitgesteuerte Schritte des Historical Data Flows
    private var historyFlowTasks: [BLEScheduledTask] = []

    /// Connection Quality Monitoring
    private var connectionMonitorTask: BLEScheduledTask?

    /// RSSI Monitoring
    private var rssiMonitorTask: BLEScheduledTask?

    /// Flag ob wir auf Characteristics Discovery warten für History Resume
    private var waitingForCharacteristicsForHistoryResume: Bool = false
    private var autoStartHistoryFlowEnabled: Bool = true

    // MARK: - Combine Publishers

    /// Subject für Connection State Updates
    /// Informiert Subscriber über Verbindungsänderungen
    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    /// Subject für Live Sensor-Daten
    /// Sendet neu empfangene Sensor-Messwerte
    private let sensorDataSubject = PassthroughSubject<SensorDataTemp, Never>()

    /// Subject für Historical Sensor-Daten
    /// Sendet historische Sensor-Daten vom Gerät
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()

    /// Subject für Historical Data Loading Progress
    /// Sendet (current, total) Updates während des History Flows
    private let historyProgressSubject = PassthroughSubject<(Int, Int), Never>()

    /// Public Publisher für Connection State
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Public Publisher für Live Sensor-Daten
    var sensorDataPublisher: AnyPublisher<SensorDataTemp, Never> {
        sensorDataSubject.eraseToAnyPublisher()
    }

    /// Public Publisher für Historical Sensor-Daten
    var historicalDataPublisher: AnyPublisher<HistoricalSensorData, Never> {
        historicalDataSubject.eraseToAnyPublisher()
    }

    /// Public Publisher für Historical Data Loading Progress
    var historyProgressPublisher: AnyPublisher<(Int, Int), Never> {
        historyProgressSubject.eraseToAnyPublisher()
    }

    /// Convenience Property für aktuellen Connection State
    var connectionState: ConnectionState {
        stateSubject.value
    }

    /// Current history loading progress (current, total)
    var currentHistoryProgress: (current: Int, total: Int) {
        (currentEntryIndex, totalEntries)
    }

    /// Whether history flow is currently active
    var isHistoryLoading: Bool {
        isHistoryFlowActive && totalEntries > 0
    }

    /// Gibt an, ob ein automatischer Reconnect gewünscht ist
    /// True wenn History Flow aktiv ist (auch wenn wir noch keine Metadata haben!)
    var shouldAutoReconnect: Bool {
        // Reconnect wenn History Flow aktiv ist, UNABHÄNGIG von totalEntries
        // Das ist wichtig für den Fall dass wir disconnecten bevor wir Metadata bekommen
        if isHistoryFlowActive {
            // Wenn wir noch keine Metadata haben (totalEntries == 0), reconnecten
            if totalEntries == 0 {
                return true
            }
            // Wenn wir Metadata haben, nur reconnecten wenn noch Entries fehlen
            return currentEntryIndex < totalEntries
        }
        return false
    }

    // MARK: - Initialization

    /// Initialisiert eine neue DeviceConnection für ein spezifisches Gerät
    /// - Parameters:
    ///   - deviceUUID: Die eindeutige UUID des BLE-Geräts
    ///   - scheduler: Zeitsteuerung; Produktion nutzt den Default (Timer auf Main RunLoop)
    init(deviceUUID: String, scheduler: BLEScheduler = MainRunLoopScheduler()) {
        self.deviceUUID = deviceUUID
        self.scheduler = scheduler
        super.init()

        AppLogger.ble.bleConnection("DeviceConnection initialized for device: \(deviceUUID)")
    }

    /// Konfiguriert, ob der History Flow automatisch nach der Authentifizierung starten soll
    func setAutoStartHistoryFlowEnabled(_ enabled: Bool) {
        autoStartHistoryFlowEnabled = enabled
        if !enabled {
            waitingForCharacteristicsForHistoryResume = false
        }
        AppLogger.ble.bleConnection("Device \(deviceUUID) autoStartHistoryFlowEnabled set to \(enabled)")
    }

    // MARK: - Public Methods

    /// Setzt das Peripheral für diese Connection und registriert sich als Delegate
    /// - Parameter peripheral: Das Peripheral-Link Objekt vom BLECentral
    /// - Note: Muss aufgerufen werden nachdem das Peripheral gefunden wurde
    func setPeripheral(_ peripheral: BLEPeripheralLink) {
        self.peripheral = peripheral
        peripheral.linkDelegate = self

        AppLogger.ble.bleConnection("Peripheral set for device \(deviceUUID): \(peripheral.name ?? "Unknown")")
    }

    /// Startet RSSI Monitoring für Verbindungsqualität
    func startRSSIMonitoring() {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            return
        }

        // Read RSSI periodically (every 5 seconds)
        rssiMonitorTask?.cancel()
        rssiMonitorTask = scheduler.scheduleRepeating(every: 5.0) { [weak self] in
            guard let self = self,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected else {
                self?.rssiMonitorTask?.cancel()
                self?.rssiMonitorTask = nil
                return
            }

            peripheral.readRSSI()
        }
    }

    /// Wird aufgerufen wenn das Peripheral erfolgreich verbunden wurde
    /// Startet die Service Discovery
    func handleConnected() {
        // Update Connection State
        stateSubject.send(.connected)

        AppLogger.ble.bleConnection("Device \(deviceUUID) connected, discovering services")

        // Starte RSSI Monitoring für Verbindungsqualität
        startRSSIMonitoring()

        // CRITICAL FIX: Discover ALL services, not just specific ones!
        // FlowerCare sensors may have different service UUIDs or additional services
        peripheral?.discoverServices()
        AppLogger.ble.bleConnection("⚠️ Discovering ALL services (like FlowerManager)")
    }

    /// Wird aufgerufen wenn das Peripheral disconnected wurde
    /// - Parameter error: Optional - Fehler falls die Disconnection ungeplant war
    func handleDisconnected(error: Error?) {
        // Reset Authentication Status
        isAuthenticated = false

        // Handle Historical Data Flow Disconnect
        if isHistoryFlowActive {
            AppLogger.ble.bleWarning("Device \(deviceUUID) disconnected during history flow at entry \(currentEntryIndex)/\(totalEntries)")

            // Don't cleanup yet - we'll try to resume
            // Only cleanup scheduled steps to prevent stale work firing
            for task in historyFlowTasks {
                task.cancel()
            }
            historyFlowTasks.removeAll()

            AppLogger.ble.info("🔄 Will attempt to resume history flow after reconnect")
        }

        // Update Connection State basierend auf Error
        if let error = error {
            stateSubject.send(.error(error))
            AppLogger.ble.bleConnection("Device \(deviceUUID) disconnected with error: \(error.localizedDescription)")
        } else {
            stateSubject.send(.disconnected)
            AppLogger.ble.bleConnection("Device \(deviceUUID) disconnected normally")
        }
    }

    /// Wird aufgerufen wenn die Verbindung nach mehreren Versuchen fehlgeschlagen ist
    /// - Parameter error: Der Grund für das Fehlschlagen
    func handleConnectionFailed(error: Error) {
        AppLogger.ble.bleError("❌ Connection failed for device \(deviceUUID): \(error.localizedDescription)")

        // Reset state
        isAuthenticated = false

        // Cleanup history flow if active
        if isHistoryFlowActive {
            cleanupHistoryFlow()
        }

        // Send error state
        stateSubject.send(.error(error))
    }

    // MARK: - Authentication

    /// Startet den Authentication-Prozess mit dem FlowerCare Sensor
    /// Verwendet den 2-Schritt Authentication Flow
    private func startAuthentication() {
        guard hasAuthenticationCharacteristic else {
            AppLogger.ble.info("🔐 No authentication characteristic found for device \(self.deviceUUID), proceeding without auth")
            // Ohne Authentication direkt als authenticated markieren
            isAuthenticated = true
            stateSubject.send(.authenticated)

            // CRITICAL FIX: Start history flow (like FlowerManager)
            // Check if required characteristics are available
            guard autoStartHistoryFlowEnabled else {
                AppLogger.ble.info("⏭️ Auto history start disabled for device \(self.deviceUUID) - waiting for explicit trigger")
                return
            }

            if hasHistoryControlCharacteristic &&
               hasHistoryDataCharacteristic &&
               hasDeviceTimeCharacteristic {
                if isHistoryFlowActive && totalEntries > 0 && currentEntryIndex < totalEntries {
                    AppLogger.ble.info("🔄 Resuming history flow (no auth) at entry \(self.currentEntryIndex)/\(self.totalEntries)")
                } else {
                    AppLogger.ble.info("🆕 Starting fresh history flow (no auth required)")
                }
                scheduler.schedule(after: 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.startHistoryDataFlow()
                }
            } else {
                AppLogger.ble.info("⏳ History flow needs to start but characteristics not ready yet, waiting for discovery")
                waitingForCharacteristicsForHistoryResume = true
            }
            return
        }

        AppLogger.ble.info("🔐 Starting FlowerCare authentication for device \(self.deviceUUID)...")
        authenticationStep = 1
        isAuthenticated = false

        // Step 1: Send authentication challenge
        let challengeData = Data([0x90, 0xCA, 0x85, 0xDE])
        AppLogger.ble.bleData("🔐 Sending auth challenge: \(challengeData.map { String(format: "%02x", $0) }.joined())")
        peripheral?.writeValue(challengeData, forCharacteristic: authenticationCharacteristicUUID, type: .withResponse)

        // Set expected response for validation
        expectedResponse = Data([0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Set a timeout for authentication
        scheduler.schedule(after: 4.0) { [weak self] in
            guard let self = self else { return }
            if self.authenticationStep > 0 && !self.isAuthenticated {
                AppLogger.ble.bleError("🔐 Authentication timeout for device \(self.deviceUUID), proceeding without auth")
                self.authenticationStep = 0
                self.isAuthenticated = true
                self.stateSubject.send(.authenticated)

                // Resume History Flow if it was active before disconnect
                if self.autoStartHistoryFlowEnabled,
                   self.isHistoryFlowActive && self.totalEntries > 0 && self.currentEntryIndex < self.totalEntries {
                    // Check if required characteristics are available
                    if self.hasHistoryControlCharacteristic &&
                       self.hasHistoryDataCharacteristic &&
                       self.hasDeviceTimeCharacteristic {
                        AppLogger.ble.info("🔄 Resuming history flow after reconnect at entry \(self.currentEntryIndex)/\(self.totalEntries)")
                        self.scheduler.schedule(after: 0.5) { [weak self] in
                            guard let self = self else { return }
                            self.startHistoryDataFlow()
                        }
                    } else {
                        AppLogger.ble.info("⏳ History flow needs to resume but characteristics not ready yet, waiting for discovery")
                        self.waitingForCharacteristicsForHistoryResume = true
                    }
                }
            }
        }
    }

    /// Behandelt die Authentication Response vom Sensor
    /// - Parameter data: Die empfangenen Daten vom Authentication Characteristic
    private func handleAuthenticationResponse(_ data: Data) {
        AppLogger.ble.bleData("🔐 Authentication response for device \(deviceUUID): \(data.map { String(format: "%02x", $0) }.joined())")

        switch authenticationStep {
        case 1:
            // Validate challenge response
            if data.starts(with: expectedResponse?.prefix(4) ?? Data()) {
                AppLogger.ble.info("✅ Authentication challenge successful for device \(self.deviceUUID)")
                authenticationStep = 2

                // Step 2: Send final authentication key
                guard hasAuthenticationCharacteristic else {
                    AppLogger.ble.bleError("❌ Authentication characteristic disappeared for device \(deviceUUID)")
                    return
                }

                let finalKey = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
                peripheral?.writeValue(finalKey, forCharacteristic: authenticationCharacteristicUUID, type: .withResponse)
            } else {
                AppLogger.ble.bleError("❌ Authentication challenge failed for device \(deviceUUID)")
                // Try authentication one more time
                startAuthentication()
            }

        case 2:
            // Final authentication step
            AppLogger.ble.info("✅ Authentication completed successfully for device \(self.deviceUUID)")
            isAuthenticated = true
            authenticationStep = 0
            stateSubject.send(.authenticated)

            // CRITICAL FIX: Start history flow after authentication (like FlowerManager)
            // This handles both initial start AND resume
            guard autoStartHistoryFlowEnabled else {
                AppLogger.ble.info("⏭️ Auto history start disabled for device \(self.deviceUUID) - waiting for explicit trigger")
                return
            }

            if hasHistoryControlCharacteristic &&
               hasHistoryDataCharacteristic &&
               hasDeviceTimeCharacteristic {
                if isHistoryFlowActive && totalEntries > 0 && currentEntryIndex < totalEntries {
                    AppLogger.ble.info("🔄 Resuming history flow after authentication at entry \(self.currentEntryIndex)/\(self.totalEntries)")
                } else {
                    AppLogger.ble.info("🆕 Starting fresh history flow after authentication")
                }
                // Small delay to let connection stabilize
                scheduler.schedule(after: 0.5) { [weak self] in
                    guard let self = self else { return }
                    self.startHistoryDataFlow()
                }
            } else {
                AppLogger.ble.bleWarning("⏳ History flow needs to start but characteristics not ready yet, waiting for discovery")
                if autoStartHistoryFlowEnabled {
                    waitingForCharacteristicsForHistoryResume = true
                }
            }

        default:
            AppLogger.ble.bleError("❌ Unexpected authentication step: \(authenticationStep) for device \(deviceUUID)")
        }
    }

    // MARK: - Live Data Requests

    /// Fordert aktuelle Live-Sensor-Daten vom FlowerCare Sensor an
    /// Schreibt Mode Change Command an das Gerät
    func requestLiveData() {
        // Prüfe ob History Flow aktiv ist - blockiere Live Data während History läuft
        if isHistoryFlowActive {
            AppLogger.ble.bleWarning("⚠️ Cannot request live data - history flow is active for device \(deviceUUID)")
            return
        }

        // Prüfe ob authentifiziert
        guard isAuthenticated else {
            AppLogger.ble.bleWarning("Cannot request live data - device \(deviceUUID) not authenticated")
            return
        }

        // Prüfe ob Peripheral verbunden ist
        guard let peripheral = peripheral, peripheral.state == .connected else {
            AppLogger.ble.bleError("Cannot request live data - device \(deviceUUID) not connected")
            return
        }

        // Prüfe ob Mode Change Characteristic entdeckt wurde
        guard discoveredCharacteristics.contains(deviceModeChangeCharacteristicUUID) else {
            AppLogger.ble.bleWarning("Cannot request live data - mode characteristic not found for device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleData("📤 Requesting live sensor data from device \(deviceUUID) - sending mode change command (0xA01F)")

        // Sende Mode Change Command
        let command: [UInt8] = [0xA0, 0x1F]
        peripheral.writeValue(Data(command), forCharacteristic: deviceModeChangeCharacteristicUUID, type: .withResponse)
    }

    /// Stoppt Live-Daten-Updates
    func stopLiveData() {
        AppLogger.ble.bleConnection("Stopping live data for device \(deviceUUID)")
        // TODO: Falls nötig, weitere Cleanup-Logik hinzufügen
    }

    // MARK: - Historical Data Methods

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
                self?.cleanupHistoryFlow()
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
                        self?.cleanupHistoryFlow()
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
                    self?.cleanupHistoryFlow()
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
                        self?.cleanupHistoryFlow()
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
    private func fetchHistoricalDataEntry(index: Int) {
        // Check if operation has been cancelled or flow is not active
        guard isHistoryFlowActive else {
            AppLogger.ble.info("❌ History data loading was cancelled or flow inactive for device \(self.deviceUUID)")
            return
        }

        guard let peripheral = peripheral,
              peripheral.state == .connected else {
            AppLogger.ble.bleError("Cannot fetch history entry: device \(deviceUUID) disconnected")
            cleanupHistoryFlow()
            return
        }

        guard hasHistoryControlCharacteristic,
              hasHistoryDataCharacteristic else {
            AppLogger.ble.bleError("Cannot fetch history entry: characteristics unavailable for device \(deviceUUID)")
            cleanupHistoryFlow()
            return
        }

        AppLogger.ble.bleData("Fetching history entry \(index) of \(totalEntries) for device \(deviceUUID)")

        // Format index correctly: 0xa1 + 2-byte index in little endian
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])

        // Write address to history control characteristic
        peripheral.writeValue(entryAddress, forCharacteristic: historyControlCharacteristicUUID, type: .withResponse)

        // Minimal delay to give the device time to respond
        let readTask = scheduler.schedule(after: 0.02) { [weak self] in
            guard let self = self,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected,
                  self.isHistoryFlowActive,
                  self.hasHistoryDataCharacteristic else {
                AppLogger.ble.bleError("Device \(self?.deviceUUID ?? "unknown") disconnected or flow cancelled before reading data")
                self?.cleanupHistoryFlow()
                return
            }

            peripheral.readValue(forCharacteristic: historicalSensorValuesCharacteristicUUID)
        }
        historyFlowTasks.append(readTask)
    }

    /// Räumt den Historical Data Flow auf und beendet ihn
    /// Can be called externally to cancel an ongoing history flow
    func cleanupHistoryFlow() {
        AppLogger.ble.info("🧹 Cleaning up history flow for device \(self.deviceUUID)")
        isHistoryFlowActive = false

        // Cancel all pending scheduled steps
        for task in historyFlowTasks {
            task.cancel()
        }
        historyFlowTasks.removeAll()

        // Stop connection monitoring
        stopConnectionQualityMonitoring()

        // Reset history state to allow fresh start
        totalEntries = 0
        currentEntryIndex = 0
        deviceBootTime = nil

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
            return
        }

        // Write erfolgreich
        // Implementierung kommt später
    }

    /// Callback wenn RSSI gelesen wurde
    func peripheralLink(_ link: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?) {
        if let error = error {
            AppLogger.ble.bleWarning("RSSI read error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        AppLogger.ble.bleConnection("📶 RSSI for device \(deviceUUID): \(rssi) dBm")

        // Signal Quality Classification:
        // > -50 dBm: Excellent
        // -50 to -60 dBm: Good
        // -60 to -70 dBm: Fair
        // < -70 dBm: Poor

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

        // TODO: Update Device Info in Database (kommt später)
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

                // Try to recover from failed decoding by skipping to the next entry
                let nextIndex = currentEntryIndex + 1
                if nextIndex < totalEntries {
                    AppLogger.ble.info("⏭️ Skipping corrupted entry \(self.currentEntryIndex), continuing with next for device \(self.deviceUUID)")
                    currentEntryIndex = nextIndex

                    let skipTask = scheduler.schedule(after: 0.1) { [weak self] in
                        self?.fetchHistoricalDataEntry(index: nextIndex)
                    }
                    self.historyFlowTasks.append(skipTask)
                } else {
                    cleanupHistoryFlow()
                }
            }
        }
    }

    // MARK: - Cleanup

    deinit {
        AppLogger.ble.bleConnection("DeviceConnection deinitialized for device \(deviceUUID)")

        // Cleanup Historical Data Flow
        cleanupHistoryFlow()

        // Stop RSSI Monitoring
        rssiMonitorTask?.cancel()

        // Reset Peripheral Delegate
        peripheral?.linkDelegate = nil
    }
}
