//
//  InitialSensorDataService.swift
//  GrowGuard
//
//  Created by Claude Code
//  Verantwortlich für die initiale Abfrage aller Sensoren beim App-Start
//

import Foundation
import Combine

/// Service für gesteuerte Live-Anfragen an alle Sensoren via ConnectionPool
/// Lädt auf Wunsch alle Geräte und fordert genau eine Live-Daten-Aktualisierung pro Gerät an
@MainActor
class InitialSensorDataService {

    // MARK: - Singleton

    static let shared = InitialSensorDataService()

    // MARK: - Properties

    /// ConnectionPool für alle Verbindungen (Tests injizieren einen Pool mit Fake-Central)
    private let pool: ConnectionPoolManager

    /// Set von Device UUIDs, für die bereits Live-Daten angefordert wurden
    private var requestedDevices: Set<String> = []

    /// Subscriptions für Connection State Changes
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(pool: ConnectionPoolManager = .shared) {
        self.pool = pool
        AppLogger.ble.info("🚀 InitialSensorDataService initialized")
    }

    // MARK: - Public Methods

    /// Startet die initiale Sensor-Abfrage für alle gespeicherten Geräte
    /// (z.B. beim manuellen Refresh auf dem Dashboard)
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

        await requestLiveData(for: devices.map { $0.uuid })
    }

    /// Fordert genau eine Live-Daten-Aktualisierung für die angegebenen Geräte über den ConnectionPool an
    /// - Parameter deviceUUIDs: Liste der zu aktualisierenden Sensor-UUIDs
    func requestLiveData(for deviceUUIDs: [String]) async {
        let targets = Array(Set(deviceUUIDs)).filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            AppLogger.ble.info("ℹ️ No sensor UUIDs provided for live data refresh")
            return
        }

        prepareNewSession()

        AppLogger.ble.info("🔄 InitialSensorDataService: Connecting to \(targets.count) sensor(s) for one-time live refresh")

        for deviceUUID in targets {
            AppLogger.ble.bleConnection("🧭 InitialSensorDataService: Observing connection state for \(deviceUUID)")
            setupConnectionObserver(for: deviceUUID)
            // Neue user-sichtbare Session: frisches Retry-Budget, sonst bleibt
            // ein früher erschöpfter Zähler für immer auf .error (Pool-Kontrakt,
            // siehe "Max-retries error is sticky until resetRetryCounter")
            pool.resetRetryCounter(for: deviceUUID)
            pool.connect(to: deviceUUID, autoStartHistoryFlow: false)
        }
    }

    // MARK: - Private Methods

    /// Bereitet internen Zustand für eine neue Refresh-Session vor
    private func prepareNewSession() {
        requestedDevices.removeAll()
        cancellables.removeAll()
    }

    /// Richtet einen Observer für den Connection State eines Geräts ein
    /// Fordert automatisch Live-Daten an, sobald das Gerät authentifiziert ist
    /// - Parameter deviceUUID: Die UUID des zu beobachtenden Geräts
    private func setupConnectionObserver(for deviceUUID: String) {
        // Hole Connection für Device
        let connection = pool.getConnection(for: deviceUUID)

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
        prepareNewSession()
    }
}
