//
//  DeviceConnection.swift
//  GrowGuard
//
//  Created by ConnectionPool Implementation
//  Verantwortlich für GENAU EINE BLE-Verbindung zu einem Sensor
//

import Foundation
import CoreBluetooth
import Combine
import OSLog

/// Verwaltet die BLE-Verbindung zu einem einzelnen Flower Care Sensor
/// Diese Klasse kapselt alle BLE-Operationen für ein spezifisches Gerät
/// und stellt isolierte Publisher für Sensor-Daten bereit
class DeviceConnection: NSObject, CBPeripheralDelegate {

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

    /// Das CoreBluetooth Peripheral Objekt
    /// Wird gesetzt sobald das Gerät gefunden wurde
    private(set) var peripheral: CBPeripheral?

    /// Aktueller Authentifizierungs-Status
    /// true = Gerät ist authentifiziert und bereit für Datenübertragung
    private var isAuthenticated = false

    /// Aktueller Authentication Step (0 = nicht gestartet, 1 = Challenge gesendet, 2 = Final Key gesendet)
    private var authenticationStep: Int = 0

    /// Erwartete Response für Authentication Validation
    private var expectedResponse: Data?

    /// Dictionary aller entdeckten BLE Characteristics
    /// Key: Characteristic UUID als String
    /// Value: CBCharacteristic Objekt
    private var characteristics: [String: CBCharacteristic] = [:]

    /// Decoder für Sensor-Daten
    /// Wandelt rohe BLE-Bytes in strukturierte Sensor-Daten um
    private let decoder = SensorDataDecoder()

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

    /// Convenience Property für aktuellen Connection State
    var connectionState: ConnectionState {
        stateSubject.value
    }

    // MARK: - Initialization

    /// Initialisiert eine neue DeviceConnection für ein spezifisches Gerät
    /// - Parameter deviceUUID: Die eindeutige UUID des BLE-Geräts
    init(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        super.init()

        AppLogger.ble.bleConnection("DeviceConnection initialized for device: \(deviceUUID)")
    }

    // MARK: - Public Methods

    /// Setzt das Peripheral für diese Connection und registriert sich als Delegate
    /// - Parameter peripheral: Das CBPeripheral Objekt vom CBCentralManager
    /// - Note: Muss aufgerufen werden nachdem das Peripheral gefunden wurde
    func setPeripheral(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self

        AppLogger.ble.bleConnection("Peripheral set for device \(deviceUUID): \(peripheral.name ?? "Unknown")")
    }

    /// Wird aufgerufen wenn das Peripheral erfolgreich verbunden wurde
    /// Startet die Service Discovery
    func handleConnected() {
        // Update Connection State
        stateSubject.send(.connected)

        AppLogger.ble.bleConnection("Device \(deviceUUID) connected, discovering services")

        // Starte Service Discovery
        peripheral?.discoverServices([flowerCareServiceUUID, dataServiceUUID, historyServiceUUID])
    }

    /// Wird aufgerufen wenn das Peripheral disconnected wurde
    /// - Parameter error: Optional - Fehler falls die Disconnection ungeplant war
    func handleDisconnected(error: Error?) {
        // Reset Authentication Status
        isAuthenticated = false

        // Update Connection State basierend auf Error
        if let error = error {
            stateSubject.send(.error(error))
            AppLogger.ble.bleConnection("Device \(deviceUUID) disconnected with error: \(error.localizedDescription)")
        } else {
            stateSubject.send(.disconnected)
            AppLogger.ble.bleConnection("Device \(deviceUUID) disconnected normally")
        }

        // TODO: Cleanup (Timer, Subscriptions, etc.) - kommt in Phase 5
    }

    // MARK: - Authentication

    /// Startet den Authentication-Prozess mit dem FlowerCare Sensor
    /// Verwendet den 2-Schritt Authentication Flow
    private func startAuthentication() {
        // Hole Authentication Characteristic aus Dictionary
        guard let authCharacteristic = characteristics[authenticationCharacteristicUUID.uuidString] else {
            AppLogger.ble.info("🔐 No authentication characteristic found for device \(deviceUUID), proceeding without auth")
            // Ohne Authentication direkt als authenticated markieren
            isAuthenticated = true
            stateSubject.send(.authenticated)
            return
        }

        AppLogger.ble.info("🔐 Starting FlowerCare authentication for device \(deviceUUID)...")
        authenticationStep = 1
        isAuthenticated = false

        // Step 1: Send authentication challenge
        let challengeData = Data([0x90, 0xCA, 0x85, 0xDE])
        AppLogger.ble.bleData("🔐 Sending auth challenge: \(challengeData.map { String(format: "%02x", $0) }.joined())")
        peripheral?.writeValue(challengeData, for: authCharacteristic, type: .withResponse)

        // Set expected response for validation
        expectedResponse = Data([0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Set a timeout for authentication
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if self.authenticationStep > 0 && !self.isAuthenticated {
                AppLogger.ble.bleError("🔐 Authentication timeout for device \(self.deviceUUID), proceeding without auth")
                self.authenticationStep = 0
                self.isAuthenticated = true
                self.stateSubject.send(.authenticated)
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
                AppLogger.ble.info("✅ Authentication challenge successful for device \(deviceUUID)")
                authenticationStep = 2

                // Step 2: Send final authentication key
                guard let authCharacteristic = characteristics[authenticationCharacteristicUUID.uuidString] else {
                    AppLogger.ble.bleError("❌ Authentication characteristic disappeared for device \(deviceUUID)")
                    return
                }

                let finalKey = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
                peripheral?.writeValue(finalKey, for: authCharacteristic, type: .withResponse)
            } else {
                AppLogger.ble.bleError("❌ Authentication challenge failed for device \(deviceUUID)")
                // Try authentication one more time
                startAuthentication()
            }

        case 2:
            // Final authentication step
            AppLogger.ble.info("✅ Authentication completed successfully for device \(deviceUUID)")
            isAuthenticated = true
            authenticationStep = 0
            stateSubject.send(.authenticated)

        default:
            AppLogger.ble.bleError("❌ Unexpected authentication step: \(authenticationStep) for device \(deviceUUID)")
        }
    }

    /// Startet die Service Discovery für das Peripheral
    /// Sucht nach den benötigten BLE Services des Flower Care Sensors
    func discoverServices() {
        guard let peripheral = peripheral else {
            AppLogger.ble.bleConnection("Cannot discover services - peripheral is nil for device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("Starting service discovery for device \(deviceUUID)")

        // TODO: Implementierung kommt in Phase 2
        // peripheral.discoverServices([flowerCareServiceUUID, dataServiceUUID, historyServiceUUID])
    }

    // MARK: - CBPeripheralDelegate Methods

    /// Callback wenn Services entdeckt wurden
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Service discovery error for device \(deviceUUID): \(error.localizedDescription)")
            stateSubject.send(.error(error))
            return
        }

        // Prüfe ob Services gefunden wurden
        guard let services = peripheral.services, !services.isEmpty else {
            AppLogger.ble.bleWarning("No services found for device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("Discovered \(services.count) service(s) for device \(deviceUUID)")

        // Iteriere über alle gefundenen Services
        for service in services {
            AppLogger.ble.bleConnection("Found service: \(service.uuid.uuidString)")

            // Starte Characteristic Discovery für jeden Service
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// Callback wenn Characteristics für einen Service entdeckt wurden
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - service: Der Service für den Characteristics gefunden wurden
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Characteristic discovery error for device \(deviceUUID): \(error.localizedDescription)")
            stateSubject.send(.error(error))
            return
        }

        // Prüfe ob Characteristics gefunden wurden
        guard let discoveredCharacteristics = service.characteristics, !discoveredCharacteristics.isEmpty else {
            AppLogger.ble.bleWarning("No characteristics found for service \(service.uuid.uuidString) on device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleConnection("Discovered \(discoveredCharacteristics.count) characteristic(s) for service \(service.uuid.uuidString) on device \(deviceUUID)")

        // Iteriere über alle gefundenen Characteristics
        for characteristic in discoveredCharacteristics {
            let uuidString = characteristic.uuid.uuidString

            // Speichere Characteristic im Dictionary
            characteristics[uuidString] = characteristic

            AppLogger.ble.bleConnection("Found characteristic: \(uuidString)")
        }

        // Starte Authentication nachdem alle Characteristics entdeckt wurden
        // Authentication wird nur einmal gestartet nach dem ersten Service Discovery
        if !isAuthenticated && authenticationStep == 0 {
            AppLogger.ble.bleConnection("All characteristics discovered for device \(deviceUUID), starting authentication")
            startAuthentication()
        }
    }

    /// Callback wenn eine Characteristic updated wurde (neue Daten empfangen)
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - characteristic: Die Characteristic die updated wurde
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Error Handling
        if let error = error {
            AppLogger.ble.bleError("Update value error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Prüfe ob wir Daten haben
        guard let value = characteristic.value else {
            AppLogger.ble.bleWarning("No value in characteristic \(characteristic.uuid.uuidString) for device \(deviceUUID)")
            return
        }

        // Handle Authentication Response wenn noch nicht authenticated
        if !isAuthenticated && characteristic.uuid == authenticationCharacteristicUUID {
            handleAuthenticationResponse(value)
            return
        }

        // TODO: Sensor-Daten Handling - kommt in Phase 3
        AppLogger.ble.bleConnection("Received data for characteristic \(characteristic.uuid.uuidString) on device \(deviceUUID)")

        // Daten verarbeiten basierend auf Characteristic
        // Authentication, Live Data, History Data etc.
        // Implementierung kommt später
    }

    /// Callback wenn Daten an eine Characteristic geschrieben wurden
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - characteristic: Die Characteristic
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // TODO: Write Response Handling - kommt in Phase 3
        AppLogger.ble.bleConnection("didWriteValueFor called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Write value error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Write erfolgreich
        // Implementierung kommt später
    }

    /// Callback wenn Notification State für eine Characteristic geändert wurde
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - characteristic: Die Characteristic
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // TODO: Notification State Handling - kommt in Phase 3
        AppLogger.ble.bleConnection("didUpdateNotificationStateFor called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Notification state error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Notification aktiviert/deaktiviert
        // Implementierung kommt später
    }

    // MARK: - Cleanup

    deinit {
        AppLogger.ble.bleConnection("DeviceConnection deinitialized for device \(deviceUUID)")

        // TODO: Cleanup in Phase 5
        // - Cancel alle Timer
        // - Unsubscribe von Notifications
        // - Reset Peripheral Delegate
    }
}
