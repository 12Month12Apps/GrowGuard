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
//  Die Klasse ist auf mehrere Dateien aufgeteilt; gemeinsamer State liegt
//  hier und ist deshalb internal statt private (Extensions in anderen
//  Dateien haben keinen Zugriff auf private Member):
//  - DeviceConnection+Authentication.swift  — FlowerCare Auth Flow
//  - DeviceConnection+LiveData.swift        — Live-Daten / LED-Blink
//  - DeviceConnection+HistoryFlow.swift     — Historical Data Sync
//  - DeviceConnection+PeripheralLink.swift  — Delegate-Callbacks + Decoding
//

import Foundation
import CoreBluetooth
import Combine
import OSLog

/// Verwaltet die BLE-Verbindung zu einem einzelnen Flower Care Sensor
/// Diese Klasse kapselt alle BLE-Operationen für ein spezifisches Gerät
/// und stellt isolierte Publisher für Sensor-Daten bereit
class DeviceConnection: NSObject {

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

    /// Geräte-Infos, die nach der Authentifizierung vom Sensor gelesen werden
    struct DeviceInfo: Equatable {
        let battery: Int
        let firmware: String
    }

    // MARK: - Public Properties

    /// UUID des Geräts - eindeutige Identifikation des Sensors
    /// Read-only, wird beim Init gesetzt und kann nicht geändert werden
    private(set) var deviceUUID: String

    // MARK: - Shared State (internal: von den Extension-Dateien genutzt)

    /// Das Peripheral hinter dem Transport-Seam
    /// Wird gesetzt sobald das Gerät gefunden wurde
    private(set) var peripheral: BLEPeripheralLink?

    /// Scheduler für alle zeitgesteuerten Abläufe (Timer-Ersatz)
    let scheduler: BLEScheduler

    /// Aktueller Authentifizierungs-Status
    /// true = Gerät ist authentifiziert und bereit für Datenübertragung
    var isAuthenticated = false

    /// Aktueller Authentication Step (0 = nicht gestartet, 1 = Challenge gesendet, 2 = Final Key gesendet)
    var authenticationStep: Int = 0

    /// Erwartete Response für Authentication Validation
    var expectedResponse: Data?

    /// Alle bisher entdeckten Characteristic-UUIDs
    var discoveredCharacteristics: Set<CBUUID> = []

    /// Decoder für Sensor-Daten
    /// Wandelt rohe BLE-Bytes in strukturierte Sensor-Daten um
    let decoder = SensorDataDecoder()

    // MARK: - Discovered Characteristics (für schnellen Zugriff)

    var hasHistoryControlCharacteristic: Bool {
        discoveredCharacteristics.contains(historyControlCharacteristicUUID)
    }

    var hasHistoryDataCharacteristic: Bool {
        discoveredCharacteristics.contains(historicalSensorValuesCharacteristicUUID)
    }

    var hasDeviceTimeCharacteristic: Bool {
        discoveredCharacteristics.contains(deviceTimeCharacteristicUUID)
    }

    var hasAuthenticationCharacteristic: Bool {
        discoveredCharacteristics.contains(authenticationCharacteristicUUID)
    }

    // MARK: - Historical Data Properties

    /// Gesamtanzahl der verfügbaren Historical Entries auf dem Gerät
    var totalEntries: Int = 0

    /// Aktueller Index beim Abrufen von Historical Data
    var currentEntryIndex: Int = 0

    /// Flag ob der Historical Data Flow aktiv ist
    var isHistoryFlowActive: Bool = false

    /// Device Boot Time für Timestamp-Berechnungen
    var deviceBootTime: Date?

    /// Laufende zeitgesteuerte Schritte des Historical Data Flows
    var historyFlowTasks: [BLEScheduledTask] = []

    // MARK: Per-Entry Retry/Skip (Reliability)

    /// Antwort-Timeout pro Entry — ein stummer Sensor friert den Flow nicht
    /// mehr bis zum globalen 10-Minuten-Timeout ein
    var entryResponseTimeoutTask: BLEScheduledTask?
    let entryResponseTimeout: TimeInterval = 2.0

    /// Retries für den aktuellen Entry (keine Antwort ODER Garbage-Frame)
    var entryRetryCount = 0
    let maxRetriesPerEntry = 2

    /// Übersprungene Entries dieses Syncs; Budget schützt vor einem Sensor,
    /// der nur noch Müll liefert
    var skippedEntryCount = 0
    var maxSkippedEntries: Int { max(20, totalEntries / 20) }

    /// Skips des zuletzt beendeten Syncs (Benchmark/UI — skippedEntryCount
    /// wird beim Cleanup zurückgesetzt)
    var lastSyncSkippedEntries = 0

    /// Connection Quality Monitoring
    var connectionMonitorTask: BLEScheduledTask?

    /// RSSI Monitoring
    private var rssiMonitorTask: BLEScheduledTask?

    /// Flag ob wir auf Characteristics Discovery warten für History Resume
    var waitingForCharacteristicsForHistoryResume: Bool = false
    private(set) var autoStartHistoryFlowEnabled: Bool = true

    /// Live-Daten-Request wartet auf die Write-Bestätigung des Mode-Change
    /// Commands, danach wird der Realtime-Wert gelesen (FlowerCare-Protokoll)
    var liveDataReadPending: Bool = false

    // MARK: - Combine Publishers

    /// Subject für Connection State Updates
    /// Informiert Subscriber über Verbindungsänderungen
    let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    /// Subject für Live Sensor-Daten
    /// Sendet neu empfangene Sensor-Messwerte
    let sensorDataSubject = PassthroughSubject<SensorDataTemp, Never>()

    /// Subject für Historical Sensor-Daten
    /// Sendet historische Sensor-Daten vom Gerät
    let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()

    /// Subject für Historical Data Loading Progress
    /// Sendet (current, total) Updates während des History Flows
    let historyProgressSubject = PassthroughSubject<(Int, Int), Never>()

    /// Subject für Geräte-Infos (Batterie/Firmware)
    let deviceInfoSubject = PassthroughSubject<DeviceInfo, Never>()

    /// Subject für RSSI-Messwerte (Verbindungsqualität)
    let rssiSubject = PassthroughSubject<Int, Never>()

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

    /// Public Publisher für Geräte-Infos (Batterie/Firmware nach Authentifizierung)
    var deviceInfoPublisher: AnyPublisher<DeviceInfo, Never> {
        deviceInfoSubject.eraseToAnyPublisher()
    }

    /// Public Publisher für RSSI-Messwerte
    var rssiPublisher: AnyPublisher<Int, Never> {
        rssiSubject.eraseToAnyPublisher()
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
            suspendHistoryFlow()
            AppLogger.ble.info("🔄 Will attempt to resume history flow after reconnect")
        }

        // Update Connection State basierend auf Error. Sensor-seitige
        // Disconnects (CBError 7) sind beim FlowerCare Normalbetrieb
        // (Idle-Timeout nach dem Auslesen) — kein Fehlerzustand fürs UI.
        if let error = error, DisconnectReason(error: error) != .peripheralDisconnected {
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
