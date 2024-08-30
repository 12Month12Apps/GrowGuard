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

struct MyAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Reload all data"

    @Parameter(title: "Device Name:")
    var name: String
    
    func perform() async throws -> some IntentResult {
        let ble = FlowerCareManager.shared
        let allSavedDevices = try await fetchSavedDevices()

        for device in allSavedDevices {
            if device.name == name {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        ble.disconnect()
                        await self.scanAndCollectData(for: device, using: ble)
                    }
                }
            }
        }

        return .result()
    }

    private func scanAndCollectData(for device: FlowerDevice, using ble: FlowerCareManager) async {
        return await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?

            ble.startScanning(device: device)

            subscription = ble.sensorDataPublisher.sink { data in
                device.sensorData.append(data)
                subscription?.cancel()
                continuation.resume()
            }
        }
    }

    @MainActor
    func fetchSavedDevices() throws -> [FlowerDevice] {
        let fetchDescriptor = FetchDescriptor<FlowerDevice>()

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
            return result
        } catch {
            print(error.localizedDescription)
            throw error
        }
    }
}


