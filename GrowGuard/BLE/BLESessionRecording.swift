//
//  BLESessionRecording.swift
//  GrowGuard
//
//  Datenmodell einer aufgezeichneten BLE-Session: alle Transport-Ereignisse
//  zwischen App und einem Sensor. Wird als JSON exportiert (Beta-Tester
//  schicken Problemfälle ein) und im Test-Target deterministisch abgespielt.
//

import Foundation

/// Eine komplette aufgezeichnete Session für ein Gerät
struct BLESessionRecording: Codable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "ble-session.json"

    var version: Int = Self.currentVersion
    var deviceUUID: String
    var deviceName: String?
    var appVersion: String
    var recordedAt: Date
    var events: [BLESessionEvent]
}

/// Ein einzelnes Transport-Ereignis. Flache optionale Felder halten das
/// JSON menschenlesbar und gut diffbar, z.B.:
/// `{"t":12.345,"type":"valueUpdated","char":"00001A12-…","data":"0d00a861…"}`
struct BLESessionEvent: Codable, Equatable {

    enum EventType: String, Codable {
        // outbound (App → Sensor/Central)
        case connectRequested
        case cancelConnect
        case discoverServices
        case discoverCharacteristics
        case write
        case read
        case readRSSI
        // inbound (Sensor/Central → App)
        case connected
        case disconnected
        case failedToConnect
        case servicesDiscovered
        case characteristicsDiscovered
        case valueUpdated
        case writeConfirmed
        case rssiRead
        case bluetoothState

        /// Ereignisse, die die App auslöst (für Replay-Matching relevant)
        var isOutbound: Bool {
            switch self {
            case .connectRequested, .cancelConnect, .discoverServices,
                 .discoverCharacteristics, .write, .read, .readRSSI:
                return true
            default:
                return false
            }
        }
    }

    /// Sekunden seit Session-Start
    var t: TimeInterval
    var type: EventType
    /// Characteristic-UUID (write/read/valueUpdated/writeConfirmed)
    var char: String?
    /// Service-UUID (discoverCharacteristics/characteristicsDiscovered)
    var service: String?
    /// Entdeckte Service-UUIDs (servicesDiscovered)
    var services: [String]?
    /// Entdeckte Characteristic-UUIDs (characteristicsDiscovered)
    var chars: [String]?
    /// Payload als Hex-String (write/valueUpdated)
    var data: String?
    var withResponse: Bool?
    var rssi: Int?
    /// CBManagerState rawValue (bluetoothState)
    var state: Int?
    var errorDomain: String?
    var errorCode: Int?
    var errorMessage: String?

    init(t: TimeInterval, type: EventType) {
        self.t = t
        self.type = type
    }

    /// Befüllt die error-Felder aus einem Swift Error (NSError-Bridge)
    mutating func setError(_ error: Error?) {
        guard let error = error else { return }
        let nsError = error as NSError
        errorDomain = nsError.domain
        errorCode = nsError.code
        errorMessage = nsError.localizedDescription
    }
}

// MARK: - Hex helpers

extension Data {
    /// Kompakte Hex-Repräsentation für Recording-Payloads
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Gegenstück zu `hexEncodedString` (Replay liest Payloads zurück)
    init?(hexEncoded string: String) {
        let characters = Array(string)
        guard characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
