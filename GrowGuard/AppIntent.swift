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
        let ble = FlowerCareManager.shared
        let matchingDevices = try await fetchDevices(withId: deviceId)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in matchingDevices {
                group.addTask {
                    ble.disconnect()
                    await scanAndCollectData(for: device, using: ble)
                }
            }
            try await group.waitForAll()
        }

        return .result()
    }

    @MainActor
    private func scanAndCollectData(for device: FlowerDeviceDTO, using ble: FlowerCareManager) async {
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?

            ble.connectToKnownDevice(deviceUUID: device.uuid)
            ble.requestLiveData()
            
            subscription = ble.sensorDataPublisher.sink { data in
                // Data is already saved by the FlowerCareManager through repositories
                // No need to manually save here anymore
                
                subscription?.cancel()
                continuation.resume()
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
