//
//  MultiDeviceTestView.swift
//  GrowGuard
//
//  Multi-Device Connection Test View
//

import SwiftUI

struct MultiDeviceTestView: View {
    @State private var connectedDevices: [String] = []
    @State private var sensorData: [String: String] = [:]

    private let pool = ConnectionPoolManager.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("Multi-Device Connection Test")
                .font(.headline)

            // Test mit deinen echten Device UUIDs
            Button("Connect to Device A") {
                testConnectDevice("6CEC514A-5F6C-0BB4-2696-85B612373B7C")
            }

            Button("Connect to Device B") {
                testConnectDevice("522A3A0D-9CDB-B617-5B64-4A3EF2DF5890")
            }

            Button("Connect to ALL Devices") {
                testConnectMultiple()
            }

            Divider()

            Text("Connected Devices: \(pool.getAllActiveConnections().count)")
                .font(.subheadline)

            List {
                ForEach(connectedDevices, id: \.self) { uuid in
                    VStack(alignment: .leading) {
                        Text(uuid)
                            .font(.caption)
                        if let data = sensorData[uuid] {
                            Text(data)
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func testConnectDevice(_ uuid: String) {
        print("🔵 Testing connection to: \(uuid)")

        // Hole Connection
        let connection = pool.getConnection(for: uuid)

        // Subscribe zu Sensor-Daten
        _ = connection.sensorDataPublisher.sink { data in
            DispatchQueue.main.async {
                sensorData[uuid] = "Temp: \(data.temperature)°C, Moisture: \(data.moisture)%"
                print("📊 Device \(uuid): \(data.temperature)°C")
            }
        }

        // Subscribe zu Connection State
        _ = connection.connectionStatePublisher.sink { state in
            DispatchQueue.main.async {
                if state == .authenticated {
                    if !connectedDevices.contains(uuid) {
                        connectedDevices.append(uuid)
                    }
                    connection.requestLiveData()
                }
            }
        }

        // Verbinde
        pool.connect(to: uuid)
    }

    private func testConnectMultiple() {
        let devices = [
            "522A3A0D-9CDB-B617-5B64-4A3EF2DF5890",
            "6CEC514A-5F6C-0BB4-2696-85B612373B7C"
        ]

        pool.connectToMultiple(deviceUUIDs: devices)

        // Subscribe zu allen
        for uuid in devices {
            testConnectDevice(uuid)
        }
    }
}

#Preview {
    MultiDeviceTestView()
}
