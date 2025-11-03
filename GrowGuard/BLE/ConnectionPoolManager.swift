//
//  ConnectionPoolManager.swift
//  GrowGuard
//
//  Created by Claude Code
//

import Foundation
import CoreBluetooth
import Combine

enum ConnectionError: Error {
    case maxRetriesExceeded
    case timeout
    case bluetoothUnavailable
    case peripheralNotFound

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
        }
    }
}

@MainActor
class ConnectionPoolManager: NSObject, CBCentralManagerDelegate {

    // MARK: - Singleton

    static let shared = ConnectionPoolManager()

    // MARK: - Properties

    private var centralManager: CBCentralManager!
    private var connections: [String: DeviceConnection] = [:]
    private var devicesToScan: Set<String> = []
    private var isScanning: Bool = false
    private let scanningStateSubject = CurrentValueSubject<Bool, Never>(false)

    // Connection retry management
    private var connectionRetryCount: [String: Int] = [:]
    private var connectionTimeouts: [String: Timer] = [:]
    private let maxRetries = 3
    private let connectionTimeout: TimeInterval = 10.0 // 10 seconds - schnellerer Timeout

    // MARK: - Initialization

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
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
        let newConnection = DeviceConnection(deviceUUID: deviceUUID)
        connections[deviceUUID] = newConnection
        return newConnection
    }

    func connect(to deviceUUID: String) {
        AppLogger.ble.bleConnection("Requested connection to device: \(deviceUUID)")

        // Hole oder erstelle DeviceConnection
        let connection = getConnection(for: deviceUUID)

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
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])

        if let peripheral = peripherals.first {
            // Peripheral gefunden - direkt verbinden
            AppLogger.ble.bleConnection("Found known peripheral for device: \(deviceUUID)")
            connection.setPeripheral(peripheral)
            centralManager.connect(peripheral, options: nil)
        } else {
            // Peripheral nicht gefunden - Scan starten
            AppLogger.ble.bleConnection("Known device not found, starting scan for: \(deviceUUID)")
            devicesToScan.insert(deviceUUID)
            startScanning()
        }
    }

    private func startConnectionTimeout(for deviceUUID: String) {
        // Cancel existing timeout
        connectionTimeouts[deviceUUID]?.invalidate()

        // Create new timeout
        let timer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                AppLogger.ble.bleWarning("⏰ Connection timeout for device \(deviceUUID)")
                self.handleConnectionTimeout(for: deviceUUID)
            }
        }

        connectionTimeouts[deviceUUID] = timer
        AppLogger.ble.bleConnection("⏱ Connection timeout started for device \(deviceUUID) (\(connectionTimeout)s)")
    }

    private func cancelConnectionTimeout(for deviceUUID: String) {
        connectionTimeouts[deviceUUID]?.invalidate()
        connectionTimeouts[deviceUUID] = nil
        AppLogger.ble.bleConnection("⏱ Connection timeout cancelled for device \(deviceUUID)")
    }

    private func handleConnectionTimeout(for deviceUUID: String) {
        AppLogger.ble.bleWarning("⏰ Handling connection timeout for device \(deviceUUID)")

        // Cancel the connection attempt
        if let connection = connections[deviceUUID],
           let peripheral = connection.peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        // Increment retry counter
        let retryCount = (connectionRetryCount[deviceUUID] ?? 0) + 1
        connectionRetryCount[deviceUUID] = retryCount

        if retryCount < maxRetries {
            // Calculate shorter exponential backoff delay
            let delay = min(Double(retryCount), 3.0) // 1s, 2s, 3s
            AppLogger.ble.bleConnection("🔄 Retrying connection in \(delay)s (attempt \(retryCount + 1)/\(maxRetries))")

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect(to: deviceUUID)
            }
        } else {
            AppLogger.ble.bleError("⛔️ Max retries reached for device \(deviceUUID)")
            if let connection = connections[deviceUUID] {
                connection.handleConnectionFailed(error: ConnectionError.maxRetriesExceeded)
            }
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
        centralManager.cancelPeripheralConnection(peripheral)
        AppLogger.ble.bleConnection("Cancelled connection for device: \(deviceUUID)")
    }

    /// Setzt den Retry Counter für ein Gerät zurück
    /// Nützlich wenn User manuell eine neue Verbindung startet
    func resetRetryCounter(for deviceUUID: String) {
        connectionRetryCount[deviceUUID] = 0
        AppLogger.ble.bleConnection("Reset retry counter for device: \(deviceUUID)")
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
        guard centralManager.state == .poweredOn else {
            AppLogger.ble.bleWarning("Cannot start scanning - Bluetooth state: \(centralManager.state.rawValue)")
            return
        }

        // Starte Scan mit Service Filter
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ]

        centralManager.scanForPeripherals(
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

        centralManager.stopScan()
        isScanning = false
        scanningStateSubject.send(false)

        AppLogger.ble.bleConnection("Stopped scanning")
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            AppLogger.ble.bleConnection("Bluetooth state changed: \(central.state.rawValue)")

            switch central.state {
            case .poweredOn:
                AppLogger.ble.bleConnection("Bluetooth is powered on")
                // Falls wir Geräte zum Scannen haben, starte Scan
                if !devicesToScan.isEmpty {
                    AppLogger.ble.bleConnection("Auto-starting scan for pending devices")
                    startScanning()
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
                AppLogger.ble.bleWarning("Bluetooth state is unknown: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let peripheralUUID = peripheral.identifier.uuidString

            AppLogger.ble.bleConnection("Discovered peripheral: \(peripheral.name ?? "Unknown") (\(peripheralUUID)) RSSI: \(RSSI)")

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
            central.connect(peripheral, options: nil)
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

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            let peripheralUUID = peripheral.identifier.uuidString

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
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let peripheralUUID = peripheral.identifier.uuidString

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

            // Informiere Connection über Disconnection
            connection.handleDisconnected(error: error)

            // Prüfe ob automatischer Reconnect gewünscht ist (z.B. während History Flow)
            if connection.shouldAutoReconnect {
                AppLogger.ble.info("🔄 Auto-reconnect requested for device \(peripheralUUID) - reconnecting in 0.5 seconds...")

                // Kurze Verzögerung vor Reconnect, um dem Gerät Zeit zur Stabilisierung zu geben
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    AppLogger.ble.info("🔄 Starting auto-reconnect for device \(peripheralUUID)")
                    self.connect(to: peripheralUUID)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let peripheralUUID = peripheral.identifier.uuidString

            AppLogger.ble.bleError("❌ Failed to connect to device: \(peripheralUUID), error: \(error?.localizedDescription ?? "unknown")")

            // Cancel timeout
            self.cancelConnectionTimeout(for: peripheralUUID)

            // Increment retry counter
            let retryCount = (self.connectionRetryCount[peripheralUUID] ?? 0) + 1
            self.connectionRetryCount[peripheralUUID] = retryCount

            if retryCount < self.maxRetries {
                // Calculate shorter exponential backoff delay
                let delay = min(Double(retryCount), 3.0) // 1s, 2s, 3s
                AppLogger.ble.bleConnection("🔄 Retrying connection in \(delay)s (attempt \(retryCount + 1)/\(self.maxRetries))")

                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.connect(to: peripheralUUID)
                }
            } else {
                AppLogger.ble.bleError("⛔️ Max retries reached for device \(peripheralUUID)")
                if let connection = self.connections[peripheralUUID] {
                    connection.handleConnectionFailed(error: error ?? ConnectionError.maxRetriesExceeded)
                }
            }
        }
    }
}
