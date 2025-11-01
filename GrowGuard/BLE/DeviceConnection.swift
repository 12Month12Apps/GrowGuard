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

        AppLogger.ble.bleConnection("Device \(deviceUUID) connected, starting service discovery")

        // TODO: Service Discovery starten (kommt in Phase 2)
        // peripheral?.discoverServices([flowerCareServiceUUID])
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
        // TODO: Service Discovery Handling - kommt in Phase 2
        AppLogger.ble.bleConnection("didDiscoverServices called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Service discovery error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Services gefunden - Characteristics Discovery starten
        // Implementierung kommt später
    }

    /// Callback wenn Characteristics für einen Service entdeckt wurden
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - service: Der Service für den Characteristics gefunden wurden
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // TODO: Characteristic Discovery Handling - kommt in Phase 2
        AppLogger.ble.bleConnection("didDiscoverCharacteristics called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Characteristic discovery error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

        // Characteristics gefunden - in Dictionary speichern
        // Implementierung kommt später
    }

    /// Callback wenn eine Characteristic updated wurde (neue Daten empfangen)
    /// - Parameters:
    ///   - peripheral: Das Peripheral
    ///   - characteristic: Die Characteristic die updated wurde
    ///   - error: Optional error
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // TODO: Data Handling - kommt in Phase 3
        AppLogger.ble.bleConnection("didUpdateValueFor called for device \(deviceUUID)")

        if let error = error {
            AppLogger.ble.bleConnection("Update value error for device \(deviceUUID): \(error.localizedDescription)")
            return
        }

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
