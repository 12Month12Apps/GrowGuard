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
    private func scanAndCollectData(for device: FlowerDevice, using ble: FlowerCareManager) async {
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?

            ble.connectToKnownDevice(device: device)

            subscription = ble.sensorDataPublisher.sink { data in
                device.sensorData.append(data)
                
                do {
                    try DataService.sharedModelContainer.mainContext.save()
                } catch {
                    print(error.localizedDescription)
                }
                
                subscription?.cancel()
                continuation.resume()
            }
        }
    }

    @MainActor
    func fetchDevices(withId uuid: String) throws -> [FlowerDevice] {
        let predicate = #Predicate { (device: FlowerDevice) in
            device.uuid == uuid
        }

        let fetchDescriptor = FetchDescriptor<FlowerDevice>(predicate: predicate)

        do {
            let result = try DataService.sharedModelContainer.mainContext.fetch(fetchDescriptor)
            return result
        } catch {
            print(error.localizedDescription)
            throw error
        }
    }
}

