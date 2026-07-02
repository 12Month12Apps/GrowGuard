//
//  BridgeProtocol.swift
//  GrowGuard (bridge client side)
//
//  Wire format for the debug-only BLE bridge: a localhost socket that lets
//  GrowGuard talk to FlowerCareSim on the same machine without a Bluetooth
//  radio. `req*` cases are central→sim; the rest are sim→central events.
//  UUIDs and payloads are strings so the JSON stays human-readable and
//  diffable, like the recording format. Pure data — no behaviour, so it is
//  not `#if DEBUG`-gated (inert in release).
//
//  ⚠️ DUPLICATED: an identical copy lives in the standalone FlowerCareSim
//  simulator project (FlowerCareSim/Shared/BridgeProtocol.swift). Both copies
//  MUST stay byte-for-byte in sync or the bridge silently stops working.
//

import Foundation

/// One framed message on the bridge socket.
enum BridgeMessage: Codable, Equatable {
    // requests (central → sim)
    case scan
    case stopScan
    case connect(id: String)
    case cancel(id: String)
    case discoverServices(id: String)
    case discoverChars(id: String, service: String)
    case read(id: String, char: String)
    case write(id: String, char: String, dataHex: String, withResponse: Bool)
    case readRSSI(id: String)
    // events (sim → central)
    case state(value: Int)
    case discovered(id: String, name: String?, services: [String], rssi: Int)
    case connected(id: String)
    case disconnected(id: String, errorCode: Int?)
    case servicesDiscovered(id: String, services: [String])
    case charsDiscovered(id: String, service: String, chars: [String])
    case valueUpdated(id: String, char: String, dataHex: String?, errorCode: Int?)
    case writeConfirmed(id: String, char: String, errorCode: Int?)
    case rssi(id: String, value: Int)
}

/// Newline-delimited JSON framing for the bridge socket.
enum BridgeCodec {
    static func encode(_ message: BridgeMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0a) // '\n'
        return data
    }

    /// Appends `newData` to `buffer`, then splits complete newline-terminated
    /// frames off the front and decodes them. Any trailing partial line stays
    /// in `buffer` for the next call.
    static func decode(appending newData: Data, to buffer: inout Data) -> [BridgeMessage] {
        buffer.append(newData)
        var messages: [BridgeMessage] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let message = try? JSONDecoder().decode(BridgeMessage.self, from: Data(line)) {
                messages.append(message)
            }
        }
        return messages
    }
}
