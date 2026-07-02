//
//  DeviceConnection+Authentication.swift
//  GrowGuard
//
//  FlowerCare 2-Schritt-Authentifizierung (Challenge → Final Key).
//  Drei Pfade führen zu completeAuthentication(): keine Auth-Characteristic
//  vorhanden, Challenge/Response erfolgreich, oder Auth-Timeout (Sensoren
//  mit stummer Auth-Characteristic).
//

import Foundation
import CoreBluetooth

extension DeviceConnection {

    /// Startet den Authentication-Prozess mit dem FlowerCare Sensor
    /// Verwendet den 2-Schritt Authentication Flow
    func startAuthentication() {
        guard hasAuthenticationCharacteristic else {
            AppLogger.ble.info("🔐 No authentication characteristic found for device \(self.deviceUUID), proceeding without auth")
            completeAuthentication()
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

        // Set a timeout for authentication. Sensors with a silent auth
        // characteristic hit this branch on EVERY connect.
        scheduler.schedule(after: 4.0) { [weak self] in
            guard let self = self else { return }
            if self.authenticationStep > 0 && !self.isAuthenticated {
                AppLogger.ble.bleError("🔐 Authentication timeout for device \(self.deviceUUID), proceeding without auth")
                self.completeAuthentication()
            }
        }
    }

    /// Markiert die Verbindung als authentifiziert, liest die Geräte-Infos
    /// (Batterie/Firmware) und startet bzw. resumed den History Flow.
    /// Gemeinsamer Endpunkt aller drei Auth-Pfade (ohne Auth-Characteristic,
    /// Challenge/Response erfolgreich, Auth-Timeout).
    private func completeAuthentication() {
        authenticationStep = 0
        isAuthenticated = true
        stateSubject.send(.authenticated)

        readDeviceInfo()

        guard autoStartHistoryFlowEnabled else {
            AppLogger.ble.info("⏭️ Auto history start disabled for device \(self.deviceUUID) - waiting for explicit trigger")
            return
        }

        if hasHistoryControlCharacteristic &&
           hasHistoryDataCharacteristic &&
           hasDeviceTimeCharacteristic {
            if isHistoryFlowActive && totalEntries > 0 && currentEntryIndex < totalEntries {
                AppLogger.ble.info("🔄 Resuming history flow at entry \(self.currentEntryIndex)/\(self.totalEntries) for device \(self.deviceUUID)")
            } else {
                AppLogger.ble.info("🆕 Starting fresh history flow for device \(self.deviceUUID)")
            }
            // Small delay to let connection stabilize
            scheduler.schedule(after: 0.5) { [weak self] in
                self?.startHistoryDataFlow()
            }
        } else {
            AppLogger.ble.info("⏳ History flow needs to start but characteristics not ready yet, waiting for discovery")
            waitingForCharacteristicsForHistoryResume = true
        }
    }

    /// Liest Batterie/Firmware vom Sensor (Antwort kommt asynchron über
    /// `didUpdateValueFor` und wird via `deviceInfoPublisher` veröffentlicht)
    private func readDeviceInfo() {
        guard discoveredCharacteristics.contains(firmwareVersionCharacteristicUUID),
              let peripheral = peripheral, peripheral.state == .connected else {
            return
        }
        peripheral.readValue(forCharacteristic: firmwareVersionCharacteristicUUID)
    }

    /// Behandelt die Authentication Response vom Sensor
    /// - Parameter data: Die empfangenen Daten vom Authentication Characteristic
    func handleAuthenticationResponse(_ data: Data) {
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
            completeAuthentication()

        default:
            AppLogger.ble.bleError("❌ Unexpected authentication step: \(authenticationStep) for device \(deviceUUID)")
        }
    }
}
