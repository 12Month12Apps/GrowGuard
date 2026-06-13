//
//  ConnectionPoolManager.swift
//  GrowGuard
//
//  Created by Claude Code
//
//  Phase 3 (BLE-Testing-Strategy.md): spricht mit dem BLECentral-Seam statt
//  direkt mit CBCentralManager und nutzt einen injizierbaren BLEScheduler.
//  Produktion verhält sich identisch (Default-Argumente erzeugen den
//  CoreBluetooth-Stack), Tests injizieren Fakes.
//

import Foundation
import CoreBluetooth
import Combine

enum ConnectionError: Error {
    case maxRetriesExceeded
    case timeout
    case bluetoothUnavailable
    case peripheralNotFound
    case disconnectLoopDetected
    case tooManyCorruptEntries

    var localizedDescription: String {
        switch self {
        case .maxRetriesExceeded:
            return "Could not connect after multiple attempts"
        case .timeout:
            return "Connection timeout"
        case .bluetoothUnavailable:
            return "Bluetooth is not available"
        case .peripheralNotFound:
            return "Device not found"
        case .disconnectLoopDetected:
            return "Connection keeps dropping without progress"
        case .tooManyCorruptEntries:
            return "Too many unreadable history entries"
        }
    }
}

@MainActor
class ConnectionPoolManager: NSObject, BLECentralDelegate {

    // MARK: - Singleton

    static let shared = ConnectionPoolManager()

    // MARK: - Properties

    private let central: BLECentral
    private let scheduler: BLEScheduler
    private var connections: [String: DeviceConnection] = [:]
    private var devicesToScan: Set<String> = []
    private var pendingConnections: [String: Bool] = [:]
    private var isScanning: Bool = false
    private let scanningStateSubject = CurrentValueSubject<Bool, Never>(false)

    // Connection retry management
    private var connectionRetryCount: [String: Int] = [:]
    /// Kumulative Fehlversuche/Reconnects seit dem letzten resetRetryCounter
    /// (Diagnose für Benchmark/UI; connectionRetryCount resettet bei Erfolg)
    private var cumulativeRetryCount: [String: Int] = [:]
    private var connectionTimeouts: [String: BLEScheduledTask] = [:]
    private let reconnectPolicy = ReconnectPolicy()
    private var loopGuards: [String: DisconnectLoopGuard] = [:]
    /// Monotone Uhr für den DisconnectLoopGuard (Tests injizieren die
    /// virtuelle Zeit des TestSchedulers)
    private let now: () -> TimeInterval
    private var maxRetries: Int { reconnectPolicy.maxAttempts }
    private let connectionTimeout: TimeInterval = 10.0 // 10 seconds - schnellerer Timeout

    /// iOS Connection Options für stabilere Verbindung
    private static let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        CBConnectPeripheralOptionNotifyOnNotificationKey: true,
        CBConnectPeripheralOptionStartDelayKey: 0 // Sofort verbinden
    ]

    // MARK: - Background Arm (pending connects, spec 2026-06-12)

    /// Geräte mit aktivem Background-Pending-Connect. Persistiert, damit ein
    /// State-Restoration-Relaunch armed-Geräte wiedererkennt.
    private var backgroundArmedDevices: Set<String> = []
    private let armedDevicesDefaultsKey = "ble_background_armed_devices"
    private let defaults: UserDefaults

    /// Meldet Geräte, deren Background-Pending-Connect zustande kam —
    /// BackgroundBLEWakeService liest dann live aus und disarmt
    private let armedConnectionSubject = PassthroughSubject<String, Never>()
    var armedConnectionPublisher: AnyPublisher<String, Never> {
        armedConnectionSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    /// Produktion nutzt `shared` (CoreBluetooth-Transport mit State Restoration).
    /// Tests injizieren ein Fake-Central und einen TestScheduler.
    init(central: BLECentral? = nil,
         scheduler: BLEScheduler = MainRunLoopScheduler(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         defaults: UserDefaults = .standard) {
        self.central = central ?? Self.makeDefaultCentral()
        self.scheduler = scheduler
        self.now = now
        self.defaults = defaults
        self.backgroundArmedDevices = Set(defaults.stringArray(forKey: armedDevicesDefaultsKey) ?? [])

        super.init()

        self.central.centralDelegate = self
    }

    /// Builds the production central. In DEBUG, when `GROWGUARD_BLE_BRIDGE` is
    /// set, returns the localhost bridge transport (single-machine testing
    /// against FlowerCareSim) instead of CoreBluetooth. Otherwise the
    /// recording-decorated CoreBluetooth central (recording is opt-in via
    /// BLESessionRecorder.isEnabled).
    private static func makeDefaultCentral() -> BLECentral {
        #if DEBUG
        if let endpoint = BLEBridgeConfig.endpoint {
            AppLogger.ble.info("🔌 BLE bridge active → \(endpoint.host):\(endpoint.port) (no radio)")
            return BridgeBLECentral(channel: NWBridgeChannel(host: endpoint.host, port: endpoint.port))
        }
        #endif
        // Initialize with options for better connection stability
        let options: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: "pro.veit.GrowGuard.centralManager",
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
        return RecordingBLECentral(wrapping: CoreBluetoothCentral(options: options))
    }

    // MARK: - Public API

    func getConnection(for deviceUUID: String) -> DeviceConnection {
        // Prüfe ob Connection bereits existiert
        if let existingConnection = connections[deviceUUID] {
            AppLogger.ble.bleConnection("Returning existing connection for device: \(deviceUUID)")
            return existingConnection
        }

        // Erstelle neue Connection
        AppLogger.ble.bleConnection("Creating new connection for device: \(deviceUUID)")
        let newConnection = DeviceConnection(deviceUUID: deviceUUID, scheduler: scheduler)
        connections[deviceUUID] = newConnection
        return newConnection
    }

    func connect(to deviceUUID: String, autoStartHistoryFlow: Bool = true) {
        AppLogger.ble.bleConnection("Requested connection to device: \(deviceUUID)")

        // Hole oder erstelle DeviceConnection
        let connection = getConnection(for: deviceUUID)
        connection.setAutoStartHistoryFlowEnabled(autoStartHistoryFlow)

        // Stelle sicher, dass Bluetooth bereit ist
        guard central.state == .poweredOn else {
            AppLogger.ble.bleWarning("Bluetooth not powered on yet. Queuing connection request for \(deviceUUID)")
            pendingConnections[deviceUUID] = autoStartHistoryFlow
            return
        }

        // Prüfe ob bereits verbunden
        if connection.connectionState == .connected || connection.connectionState == .authenticated {
            AppLogger.ble.bleConnection("Device \(deviceUUID) is already connected")
            return
        }

        // Check retry count
        let retryCount = connectionRetryCount[deviceUUID] ?? 0
        if retryCount >= maxRetries {
            AppLogger.ble.bleError("⛔️ Max connection retries (\(maxRetries)) reached for device \(deviceUUID)")
            // Send error state
            connection.handleConnectionFailed(error: ConnectionError.maxRetriesExceeded)
            return
        }

        AppLogger.ble.bleConnection("Connection attempt \(retryCount + 1)/\(maxRetries) for device: \(deviceUUID)")

        // Erstelle UUID aus String
        guard let uuid = UUID(uuidString: deviceUUID) else {
            AppLogger.ble.bleError("Invalid device UUID: \(deviceUUID)")
            return
        }

        // Start connection timeout
        startConnectionTimeout(for: deviceUUID)

        // Versuche bekanntes Peripheral abzurufen
        let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])

        if let peripheral = peripherals.first {
            // Peripheral gefunden - direkt verbinden
            AppLogger.ble.bleConnection("Found known peripheral for device: \(deviceUUID)")
            connection.setPeripheral(peripheral)
            central.connect(peripheral, options: Self.connectOptions)
        } else {
            // Peripheral nicht gefunden - Scan starten
            AppLogger.ble.bleConnection("Known device not found, starting scan for: \(deviceUUID)")
            devicesToScan.insert(deviceUUID)
            startScanning()
        }
    }

    private func startConnectionTimeout(for deviceUUID: String) {
        // Cancel existing timeout
        connectionTimeouts[deviceUUID]?.cancel()

        // Create new timeout
        let task = scheduler.schedule(after: connectionTimeout) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                AppLogger.ble.bleWarning("⏰ Connection timeout for device \(deviceUUID)")
                self.handleConnectionTimeout(for: deviceUUID)
            }
        }

        connectionTimeouts[deviceUUID] = task
        AppLogger.ble.bleConnection("⏱ Connection timeout started for device \(deviceUUID) (\(connectionTimeout)s)")
    }

    private func cancelConnectionTimeout(for deviceUUID: String) {
        connectionTimeouts[deviceUUID]?.cancel()
        connectionTimeouts[deviceUUID] = nil
        AppLogger.ble.bleConnection("⏱ Connection timeout cancelled for device \(deviceUUID)")
    }

    private func handleConnectionTimeout(for deviceUUID: String) {
        AppLogger.ble.bleWarning("⏰ Handling connection timeout for device \(deviceUUID)")

        // Cancel the connection attempt
        if let connection = connections[deviceUUID],
           let peripheral = connection.peripheral {
            central.cancelConnection(peripheral)
        }

        handleAttemptFailure(for: deviceUUID, reason: .appTimeout, underlyingError: nil)
    }

    /// Gemeinsame Backoff-Behandlung für fehlgeschlagene Verbindungsversuche
    /// (Watchdog-Timeout und didFailToConnect)
    private func handleAttemptFailure(for deviceUUID: String, reason: DisconnectReason, underlyingError: Error?) {
        let attempt = (connectionRetryCount[deviceUUID] ?? 0) + 1
        connectionRetryCount[deviceUUID] = attempt
        cumulativeRetryCount[deviceUUID, default: 0] += 1

        // Retry/Queue dürfen die Session-Konfiguration nicht überschreiben —
        // eine Live-only-Session (Dashboard/Background) bleibt Live-only
        let historyFlag = connections[deviceUUID]?.autoStartHistoryFlowEnabled ?? true

        switch reconnectPolicy.decision(attempt: attempt, reason: reason) {
        case .retry(let delay):
            AppLogger.ble.bleConnection("🔄 Retrying connection in \(delay)s (attempt \(attempt + 1)/\(maxRetries), reason: \(reason))")
            scheduler.schedule(after: delay) { [weak self] in
                Task { @MainActor in
                    self?.connect(to: deviceUUID, autoStartHistoryFlow: historyFlag)
                }
            }
        case .giveUp:
            AppLogger.ble.bleError("⛔️ Max retries reached for device \(deviceUUID)")
            if let connection = connections[deviceUUID] {
                connection.handleConnectionFailed(error: underlyingError ?? ConnectionError.maxRetriesExceeded)
            }
        case .waitForBluetooth:
            AppLogger.ble.bleWarning("📴 Bluetooth unavailable, queuing connection for \(deviceUUID)")
            pendingConnections[deviceUUID] = historyFlag
        }
    }

    func disconnect(from deviceUUID: String) {
        AppLogger.ble.bleConnection("Disconnecting from device: \(deviceUUID)")

        // Cancel any pending timeouts
        cancelConnectionTimeout(for: deviceUUID)

        // Hole Connection aus Dictionary
        guard let connection = connections[deviceUUID] else {
            AppLogger.ble.bleWarning("No connection found for device: \(deviceUUID)")
            return
        }

        // Prüfe ob Peripheral existiert
        guard let peripheral = connection.peripheral else {
            AppLogger.ble.bleWarning("No peripheral found for device: \(deviceUUID)")
            return
        }

        // Verbindung trennen
        central.cancelConnection(peripheral)
        AppLogger.ble.bleConnection("Cancelled connection for device: \(deviceUUID)")
    }

    /// Fast reconnect: retrievePeripherals mehrfach probieren bevor gescannt
    /// wird (Cache-Treffer ist sofort, Scan dauert 3-10 Sekunden).
    /// Läuft komplett über den Scheduler — in Tests deterministisch.
    private func attemptFastReconnect(for deviceUUID: String, connection: DeviceConnection, attempt: Int = 1) {
        guard let uuid = UUID(uuidString: deviceUUID) else {
            AppLogger.ble.bleError("Invalid device UUID: \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("🔍 Fast-reconnect retrieve attempt \(attempt)/3 for device: \(deviceUUID)")

        if let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            AppLogger.ble.info("✅ Fast reconnect found peripheral in cache for device: \(deviceUUID)")
            connection.setPeripheral(peripheral)
            startConnectionTimeout(for: deviceUUID)
            central.connect(peripheral, options: Self.connectOptions)
        } else if attempt < 3 {
            scheduler.schedule(after: 0.3) { [weak self] in
                Task { @MainActor in
                    self?.attemptFastReconnect(for: deviceUUID, connection: connection, attempt: attempt + 1)
                }
            }
        } else {
            AppLogger.ble.info("📡 All fast reconnect attempts failed, falling back to scanning for device: \(deviceUUID)")
            devicesToScan.insert(deviceUUID)
            startScanning()
        }
    }

    /// Setzt den Retry Counter und den Disconnect-Loop-Guard für ein Gerät
    /// zurück. Nützlich wenn User manuell eine neue Verbindung startet.
    func resetRetryCounter(for deviceUUID: String) {
        connectionRetryCount[deviceUUID] = 0
        cumulativeRetryCount[deviceUUID] = 0
        loopGuards[deviceUUID]?.reset()
        AppLogger.ble.bleConnection("Reset retry counter for device: \(deviceUUID)")
    }

    /// Fehlversuche + Auto-Reconnects seit dem letzten resetRetryCounter
    /// (read-only Diagnose für Benchmark/UI)
    func retryCount(for deviceUUID: String) -> Int {
        cumulativeRetryCount[deviceUUID] ?? 0
    }

    // MARK: - Background Arm API

    /// Pending-Connect ohne Watchdog/Retry-Budget: iOS verbindet, sobald der
    /// Sensor advertised — Minuten oder Stunden später. Der Connect überlebt
    /// App-Suspension und (mit State Restoration) System-Termination.
    func armBackgroundConnect(for deviceUUID: String) {
        guard let uuid = UUID(uuidString: deviceUUID) else {
            AppLogger.ble.bleError("armBackgroundConnect: invalid UUID \(deviceUUID)")
            return
        }

        let connection = getConnection(for: deviceUUID)

        // Laufenden History-Sync nicht kapern (Auto-Reconnect hält ihn am Leben)
        guard !connection.isHistoryFlowActive else {
            AppLogger.ble.bleConnection("armBackgroundConnect: history flow active for \(deviceUUID), skipping")
            return
        }

        connection.setAutoStartHistoryFlowEnabled(false)
        backgroundArmedDevices.insert(deviceUUID)
        persistArmedDevices()

        guard central.state == .poweredOn else {
            // Bleibt armed; der poweredOn-Handler re-armt aus dem Set
            AppLogger.ble.bleWarning("armBackgroundConnect: Bluetooth not ready, \(deviceUUID) stays armed")
            return
        }

        if connection.connectionState == .connected || connection.connectionState == .authenticated {
            AppLogger.ble.bleConnection("armBackgroundConnect: \(deviceUUID) already connected, emitting wake")
            armedConnectionSubject.send(deviceUUID)
            return
        }

        guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            // Kein Scan-Fallback: Background-Scans sind langsam; das Gerät war
            // schon mal verbunden, der nächste Trigger versucht es erneut
            AppLogger.ble.bleWarning("armBackgroundConnect: \(deviceUUID) not in retrieve cache, stays armed")
            return
        }

        connection.setPeripheral(peripheral)
        central.connect(peripheral, options: Self.connectOptions)
        AppLogger.ble.bleConnection("🛡 Armed background pending connect for \(deviceUUID)")
    }

    func disarmBackgroundConnect(for deviceUUID: String) {
        backgroundArmedDevices.remove(deviceUUID)
        persistArmedDevices()
    }

    func disarmAllBackgroundConnects() {
        backgroundArmedDevices.removeAll()
        persistArmedDevices()
    }

    func isBackgroundArmed(_ deviceUUID: String) -> Bool {
        backgroundArmedDevices.contains(deviceUUID)
    }

    private func persistArmedDevices() {
        defaults.set(Array(backgroundArmedDevices), forKey: armedDevicesDefaultsKey)
    }

    func connectToMultiple(deviceUUIDs: [String]) {
        AppLogger.ble.bleConnection("Connecting to multiple devices: \(deviceUUIDs.count)")

        for deviceUUID in deviceUUIDs {
            connect(to: deviceUUID)
        }
    }

    func getAllActiveConnections() -> [DeviceConnection] {
        let activeConnections = connections.values.filter { connection in
            connection.connectionState == .connected || connection.connectionState == .authenticated
        }

        AppLogger.ble.bleConnection("Active connections: \(activeConnections.count) out of \(connections.count) total")
        return Array(activeConnections)
    }

    // MARK: - Private Methods

    private func startScanning() {
        // Prüfe ob bereits am Scannen
        guard !isScanning else {
            AppLogger.ble.bleWarning("Already scanning, skipping startScanning()")
            return
        }

        // Prüfe Bluetooth State
        guard central.state == .poweredOn else {
            AppLogger.ble.bleWarning("Cannot start scanning - Bluetooth state: \(central.state.rawValue)")
            return
        }

        // Starte Scan mit Service Filter
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ]

        central.scanForPeripherals(
            withServices: [flowerCareServiceUUID],
            options: options
        )

        isScanning = true
        scanningStateSubject.send(true)

        AppLogger.ble.bleConnection("Started scanning for devices: \(devicesToScan)")
    }

    private func stopScanning() {
        // Prüfe ob überhaupt am Scannen
        guard isScanning else {
            AppLogger.ble.bleWarning("Not scanning, skipping stopScanning()")
            return
        }

        central.stopScan()
        isScanning = false
        scanningStateSubject.send(false)

        AppLogger.ble.bleConnection("Stopped scanning")
    }

    // MARK: - BLECentralDelegate

    nonisolated func central(_ central: BLECentral, didUpdateState state: CBManagerState) {
        Task { @MainActor in
            AppLogger.ble.bleConnection("Bluetooth state changed: \(state.rawValue)")

            switch state {
            case .poweredOn:
                AppLogger.ble.bleConnection("Bluetooth is powered on")
                // Falls wir Geräte zum Scannen haben, starte Scan
                if !devicesToScan.isEmpty {
                    AppLogger.ble.bleConnection("Auto-starting scan for pending devices")
                    startScanning()
                }
                if !pendingConnections.isEmpty {
                    let queued = pendingConnections
                    pendingConnections.removeAll()
                    AppLogger.ble.bleConnection("Processing \(queued.count) queued connection request(s) after Bluetooth became available")
                    for (uuid, historyFlag) in queued {
                        connect(to: uuid, autoStartHistoryFlow: historyFlag)
                    }
                }
                // Re-issue pending connects für armed Geräte (Restoration-
                // Relaunch oder BT-Toggle); für bereits pendende Peripherals
                // ein No-Op
                for deviceUUID in Array(backgroundArmedDevices) {
                    armBackgroundConnect(for: deviceUUID)
                }
            case .poweredOff:
                AppLogger.ble.bleError("Bluetooth is powered off")
            case .unsupported:
                AppLogger.ble.bleError("Bluetooth is not supported on this device")
            case .unauthorized:
                AppLogger.ble.bleError("Bluetooth access is unauthorized")
            case .resetting:
                AppLogger.ble.bleWarning("Bluetooth is resetting")
            case .unknown:
                AppLogger.ble.bleWarning("Bluetooth state is unknown")
            @unknown default:
                AppLogger.ble.bleWarning("Bluetooth state is unknown: \(state.rawValue)")
            }
        }
    }

    nonisolated func central(_ central: BLECentral, didDiscover peripheral: BLEPeripheralLink, advertisementData: [String: Any], rssi: NSNumber) {
        let peripheralUUID = peripheral.identifier.uuidString
        let peripheralName = peripheral.name

        Task { @MainActor in
            AppLogger.ble.bleConnection("Discovered peripheral: \(peripheralName ?? "Unknown") (\(peripheralUUID)) RSSI: \(rssi)")

            // Prüfe ob wir nach diesem Gerät suchen
            guard devicesToScan.contains(peripheralUUID) else {
                AppLogger.ble.bleConnection("Peripheral \(peripheralUUID) not in scan list, ignoring")
                return
            }

            AppLogger.ble.bleConnection("Found target device: \(peripheralUUID)")

            // Hole Connection
            let connection = getConnection(for: peripheralUUID)

            // Setze Peripheral
            connection.setPeripheral(peripheral)

            // Verbinde
            self.central.connect(peripheral, options: Self.connectOptions)
            AppLogger.ble.bleConnection("Connecting to peripheral: \(peripheralUUID)")

            // Entferne aus Scan-Liste
            devicesToScan.remove(peripheralUUID)
            AppLogger.ble.bleConnection("Removed \(peripheralUUID) from scan list. Remaining: \(devicesToScan)")

            // Stoppe Scan falls keine weiteren Geräte zu suchen sind
            if devicesToScan.isEmpty {
                AppLogger.ble.bleConnection("All target devices found, stopping scan")
                stopScanning()
            }
        }
    }

    nonisolated func central(_ central: BLECentral, didConnect peripheral: BLEPeripheralLink) {
        let peripheralUUID = peripheral.identifier.uuidString

        Task { @MainActor in
            AppLogger.ble.bleConnection("✅ Successfully connected to device: \(peripheralUUID)")

            // Cancel connection timeout
            self.cancelConnectionTimeout(for: peripheralUUID)

            // Reset retry counter on successful connection
            self.connectionRetryCount[peripheralUUID] = 0

            // Hole Connection aus Dictionary
            guard let connection = connections[peripheralUUID] else {
                AppLogger.ble.bleWarning("No connection found for connected device: \(peripheralUUID)")
                return
            }

            // Informiere Connection über erfolgreiche Verbindung
            connection.handleConnected()

            if backgroundArmedDevices.contains(peripheralUUID) {
                AppLogger.ble.info("🛡 Background-armed connect completed for \(peripheralUUID)")
                armedConnectionSubject.send(peripheralUUID)
            }
        }
    }

    nonisolated func central(_ central: BLECentral, didDisconnect peripheral: BLEPeripheralLink, error: Error?) {
        let peripheralUUID = peripheral.identifier.uuidString

        Task { @MainActor in
            // Cancel timeout if active
            self.cancelConnectionTimeout(for: peripheralUUID)

            // Logging basierend auf Error
            if let error = error {
                AppLogger.ble.bleError("Disconnected from device: \(peripheralUUID) with error: \(error.localizedDescription)")
            } else {
                AppLogger.ble.bleConnection("Disconnected from device: \(peripheralUUID)")
            }

            // Hole Connection aus Dictionary
            guard let connection = connections[peripheralUUID] else {
                AppLogger.ble.bleWarning("No connection found for disconnected device: \(peripheralUUID)")
                return
            }

            // Fortschritt VOR handleDisconnected festhalten — der Loop-Guard
            // braucht den Index zum Zeitpunkt des Disconnects
            let historyIndex = connection.currentHistoryProgress.current

            // Informiere Connection über Disconnection
            connection.handleDisconnected(error: error)

            // Prüfe ob automatischer Reconnect gewünscht ist (z.B. während History Flow)
            if connection.shouldAutoReconnect {
                // Loop-Guard: viele Disconnects ohne Sync-Fortschritt sind
                // eine Schleife — abbrechen statt endlos reconnecten
                let timestamp = self.now()
                var loopGuard = loopGuards[peripheralUUID] ?? DisconnectLoopGuard()
                loopGuard.recordDisconnect(at: timestamp, historyIndex: historyIndex)
                loopGuards[peripheralUUID] = loopGuard

                if loopGuard.isLooping(at: timestamp) {
                    AppLogger.ble.bleError("🔁 Disconnect loop detected for device \(peripheralUUID) - stopping reconnect attempts")
                    connection.cleanupHistoryFlow()
                    connection.handleConnectionFailed(error: ConnectionError.disconnectLoopDetected)
                    return
                }

                let reason = DisconnectReason(error: error)
                let delay = reconnectPolicy.reconnectDelay(reason: reason)
                cumulativeRetryCount[peripheralUUID, default: 0] += 1
                AppLogger.ble.info("🔄 Auto-reconnect for device \(peripheralUUID) in \(delay)s (reason: \(String(describing: reason)))")

                scheduler.schedule(after: delay) { [weak self] in
                    Task { @MainActor in
                        guard let self = self else { return }
                        AppLogger.ble.info("🔄 Starting auto-reconnect for device \(peripheralUUID)")
                        self.attemptFastReconnect(for: peripheralUUID, connection: connection)
                    }
                }
            }
        }
    }

    nonisolated func central(_ central: BLECentral, didFailToConnect peripheral: BLEPeripheralLink, error: Error?) {
        let peripheralUUID = peripheral.identifier.uuidString

        Task { @MainActor in
            AppLogger.ble.bleError("❌ Failed to connect to device: \(peripheralUUID), error: \(error?.localizedDescription ?? "unknown")")

            // Cancel timeout
            self.cancelConnectionTimeout(for: peripheralUUID)

            if self.backgroundArmedDevices.contains(peripheralUUID) {
                // Armed Connects haben kein Retry-Budget: bleiben armed, der
                // nächste Trigger oder poweredOn re-issued den Pending-Connect
                AppLogger.ble.bleWarning("Armed connect failed for \(peripheralUUID) — staying armed, no retry burn")
                return
            }

            self.handleAttemptFailure(for: peripheralUUID, reason: .failedToConnect, underlyingError: error)
        }
    }

    // MARK: - State Restoration

    /// Wird aufgerufen wenn iOS den CentralManager nach einem App-Kill wiederherstellt
    nonisolated func central(_ central: BLECentral, willRestoreState peripherals: [BLEPeripheralLink]) {
        Task { @MainActor in
            AppLogger.ble.bleConnection("🔄 Restoring Central Manager state")
            AppLogger.ble.bleConnection("📱 Restoring \(peripherals.count) peripherals")

            for peripheral in peripherals {
                let peripheralUUID = peripheral.identifier.uuidString
                AppLogger.ble.bleConnection("🔄 Restoring connection for device: \(peripheralUUID)")

                let connection = self.getConnection(for: peripheralUUID)
                connection.setPeripheral(peripheral)

                // If peripheral is already connected, trigger handleConnected
                if peripheral.state == .connected {
                    AppLogger.ble.bleConnection("✅ Device \(peripheralUUID) already connected after restore")
                    connection.handleConnected()

                    if backgroundArmedDevices.contains(peripheralUUID) {
                        AppLogger.ble.info("🛡 Restored armed connection for \(peripheralUUID), emitting wake")
                        armedConnectionSubject.send(peripheralUUID)
                    }
                }
            }
        }
    }
}
