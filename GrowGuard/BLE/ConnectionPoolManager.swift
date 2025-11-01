//
//  ConnectionPoolManager.swift
//  GrowGuard
//
//  Created by Claude Code
//

import Foundation
import CoreBluetooth
import Combine

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

        // Erstelle UUID aus String
        guard let uuid = UUID(uuidString: deviceUUID) else {
            AppLogger.ble.bleError("Invalid device UUID: \(deviceUUID)")
            return
        }

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

    func disconnect(from deviceUUID: String) {
        AppLogger.ble.bleConnection("Disconnecting from device: \(deviceUUID)")

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

            AppLogger.ble.bleConnection("Connected to device: \(peripheralUUID)")

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
        }
    }
}
