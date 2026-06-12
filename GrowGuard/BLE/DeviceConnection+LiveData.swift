//
//  DeviceConnection+LiveData.swift
//  GrowGuard
//
//  Live-Daten-Anforderung und LED-Blink über die Mode-Change Characteristic.
//  FlowerCare liefert Live-Daten per Read nach bestätigtem Mode Change
//  (0xA01F) — der Read selbst passiert im didWriteValueFor-Callback
//  (DeviceConnection+PeripheralLink.swift).
//

import Foundation
import CoreBluetooth

extension DeviceConnection {

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

        // Sende Mode Change Command; der Read folgt nach der Write-Bestätigung
        // (FlowerCare liefert Live-Daten per Read, nicht per Notification —
        // gleicher Ablauf wie im FlowerCareManager)
        liveDataReadPending = true
        let command: [UInt8] = [0xA0, 0x1F]
        peripheral.writeValue(Data(command), forCharacteristic: deviceModeChangeCharacteristicUUID, type: .withResponse)
    }

    /// Lässt die LED des Sensors blinken (Befehl 0xFDFF auf der Mode-Change
    /// Characteristic — gleiche Characteristic wie beim FlowerCareManager)
    func blinkLED() {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            AppLogger.ble.bleWarning("Cannot blink LED - device \(deviceUUID) not connected")
            return
        }

        guard discoveredCharacteristics.contains(deviceModeChangeCharacteristicUUID) else {
            AppLogger.ble.bleWarning("Cannot blink LED - mode characteristic not found for device \(deviceUUID)")
            return
        }

        AppLogger.ble.bleData("💡 Sending LED blink command (0xFDFF) to device \(deviceUUID)")
        peripheral.writeValue(Data([0xFD, 0xFF]), forCharacteristic: deviceModeChangeCharacteristicUUID, type: .withResponse)
    }

    /// Stoppt Live-Daten-Updates
    func stopLiveData() {
        AppLogger.ble.bleConnection("Stopping live data for device \(deviceUUID)")
        // TODO: Falls nötig, weitere Cleanup-Logik hinzufügen
    }
}
