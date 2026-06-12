//
//  AppIntent.swift
//  GrowGuard
//
//  Created by Veit Progl on 13.07.24.
//

import AppIntents
import Foundation
import Combine
import SwiftData
import CoreData

struct MyAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Reload data for single device"

    @Parameter(title: "Device ID:")
    var deviceId: String

    func perform() async throws -> some IntentResult {
        let matchingDevices = try await fetchDevices(withId: deviceId)

        for device in matchingDevices {
            await scanAndCollectData(for: device)
        }

        return .result()
    }

    /// Verbindet über den ConnectionPool, holt einmal Live-Daten, speichert
    /// sie und trennt wieder. Ein Timeout stellt sicher, dass Siri nie hängt.
    @MainActor
    private func scanAndCollectData(for device: FlowerDeviceDTO) async {
        let pool = ConnectionPoolManager.shared
        let connection = pool.getConnection(for: device.uuid)
        connection.setAutoStartHistoryFlowEnabled(false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var cancellables = Set<AnyCancellable>()
            var finished = false

            @MainActor func finish() {
                guard !finished else { return }
                finished = true
                cancellables.removeAll()
                pool.disconnect(from: device.uuid)
                continuation.resume()
            }

            connection.sensorDataPublisher
                .sink { data in
                    Task { @MainActor in
                        do {
                            // DeviceConnection publishes only - persist here
                            _ = try await PlantMonitorService.shared.validateSensorData(data, deviceUUID: device.uuid, source: .liveUserTriggered)
                            AppLogger.ble.info("📲 AppIntent: Saved live data for device \(device.uuid)")
                        } catch {
                            AppLogger.ble.bleError("📲 AppIntent: Failed to save live data: \(error.localizedDescription)")
                        }
                        finish()
                    }
                }
                .store(in: &cancellables)

            connection.connectionStatePublisher
                .sink { state in
                    Task { @MainActor in
                        switch state {
                        case .authenticated:
                            connection.requestLiveData()
                        case .error:
                            finish()
                        default:
                            break
                        }
                    }
                }
                .store(in: &cancellables)

            pool.resetRetryCounter(for: device.uuid)
            pool.connect(to: device.uuid, autoStartHistoryFlow: false)

            // Safety timeout so the intent always completes
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                finish()
            }
        }
    }

    @MainActor
    func fetchDevices(withId uuid: String) async throws -> [FlowerDeviceDTO] {
        do {
            if let device = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: uuid) {
                return [device]
            } else {
                return []
            }
        } catch {
            print("Error fetching device: \(error.localizedDescription)")
            throw error
        }
    }
}
