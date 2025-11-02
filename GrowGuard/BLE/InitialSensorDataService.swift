//
//  InitialSensorDataService.swift
//  GrowGuard
//
//  Created by Claude Code
//  Verantwortlich für die initiale Abfrage aller Sensoren beim App-Start
//

import Foundation
import Combine

/// Service für die automatische initiale Abfrage aller Sensoren beim App-Start
/// Lädt alle gespeicherten Geräte und fordert einmal Live-Daten von jedem Gerät an
@MainActor
class InitialSensorDataService {

    // MARK: - Singleton

    static let shared = InitialSensorDataService()

    // MARK: - Properties

    /// Set von Device UUIDs, für die bereits Live-Daten angefordert wurden
    private var requestedDevices: Set<String> = []

    /// Subscriptions für Connection State Changes
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    private init() {
        AppLogger.ble.info("🚀 InitialSensorDataService initialized")
    }

    // MARK: - Public Methods

    /// Startet die initiale Sensor-Abfrage für alle gespeicherten Geräte
    /// Diese Methode sollte beim App-Start aufgerufen werden
    func startInitialDataCollection() async {
        AppLogger.ble.info("🚀 Starting initial sensor data collection for all devices")

        // Lade alle gespeicherten Geräte
        let devices: [FlowerDeviceDTO]
        do {
            devices = try await RepositoryManager.shared.flowerDeviceRepository.getAllDevices()
            AppLogger.ble.info("📱 Found \(devices.count) saved device(s)")
        } catch {
            AppLogger.ble.bleError("❌ Failed to load devices from repository: \(error.localizedDescription)")
            return
        }

        // Prüfe ob überhaupt Geräte vorhanden sind
        guard !devices.isEmpty else {
            AppLogger.ble.info("ℹ️ No devices found - skipping initial data collection")
            return
        }

        // Extrahiere Device UUIDs
        let deviceUUIDs = devices.map { $0.uuid }

        // Verbinde mit allen Geräten über den Connection Pool
        AppLogger.ble.info("🔄 Connecting to \(deviceUUIDs.count) device(s) via Connection Pool")
        ConnectionPoolManager.shared.connectToMultiple(deviceUUIDs: deviceUUIDs)

        // Für jedes Gerät: Warte auf Authentication und fordere dann Live-Daten an
        for deviceUUID in deviceUUIDs {
            setupConnectionObserver(for: deviceUUID)
        }
    }

    // MARK: - Private Methods

    /// Richtet einen Observer für den Connection State eines Geräts ein
    /// Fordert automatisch Live-Daten an, sobald das Gerät authentifiziert ist
    /// - Parameter deviceUUID: Die UUID des zu beobachtenden Geräts
    private func setupConnectionObserver(for deviceUUID: String) {
        // Hole Connection für Device
        let connection = ConnectionPoolManager.shared.getConnection(for: deviceUUID)

        // Subscribe zu Connection State Changes
        connection.connectionStatePublisher
            .sink { [weak self] state in
                guard let self = self else { return }

                // Prüfe ob Gerät authentifiziert ist
                if state == .authenticated {
                    // Prüfe ob bereits angefordert
                    guard !self.requestedDevices.contains(deviceUUID) else {
                        AppLogger.ble.bleConnection("Device \(deviceUUID) already requested, skipping")
                        return
                    }

                    // Markiere als angefordert
                    self.requestedDevices.insert(deviceUUID)

                    AppLogger.ble.info("✅ Device \(deviceUUID) authenticated - requesting initial live data")

                    // Fordere Live-Daten an
                    connection.requestLiveData()
                }
            }
            .store(in: &cancellables)
    }

    /// Setzt den Service zurück (z.B. für App-Neustart oder Testing)
    func reset() {
        AppLogger.ble.info("🔄 Resetting InitialSensorDataService")
        requestedDevices.removeAll()
        cancellables.removeAll()
    }
}
