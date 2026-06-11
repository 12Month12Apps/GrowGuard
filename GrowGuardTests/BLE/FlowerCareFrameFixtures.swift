//
//  FlowerCareFrameFixtures.swift
//  GrowGuardTests
//
//  Named BLE frames for decoder golden tests.
//
//  ## Adding real frames from a device
//
//  The app logs every received frame as a hex string (AppLogger / bleData,
//  exportable via LogExportView). To turn a logged frame into a fixture:
//
//    1. Run a live read or history sync against a real sensor.
//    2. Export the log and copy the "Raw data (hex)" / "Raw historical data"
//       hex string.
//    3. Add it below via `Data(hexString:)` with a comment stating device,
//       firmware version, and the values shown in the FlowerCare app at the
//       time — those are the expected values for the golden test.
//
//  Frames marked SYNTHETIC are constructed from the documented wire format
//  (matching the reverse-engineered FlowerCare protocol used by all
//  open-source implementations) and exist to cover paths we have no
//  recording for yet, e.g. sub-zero temperatures.
//

import Foundation

extension Data {
    /// Creates Data from a hex string as logged by AppLogger, e.g. "ef000 3b9…".
    /// Whitespace is ignored so log output can be pasted directly.
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

enum FlowerCareFrames {

    // MARK: - Real-time sensor values (characteristic 00001a01)
    //
    // Wire format (16 bytes):
    //   temperature Int16 LE x10 (2) | skip (1) | brightness UInt32 LE (2..6)
    //   | moisture UInt8 (7) | conductivity UInt16 LE (8..9) | unused (10..15)

    /// RECORDED from a real sensor (debug session 2024-10).
    /// Expected: 23.9 °C, 185 lux, 51 %, 1019 µS/cm
    static let liveRecorded = Data([
        239, 0, 3, 185, 0, 0, 0, 51, 251, 3, 2, 60, 0, 251, 52, 155
    ])

    /// SYNTHETIC: sub-zero reading, -1.5 °C (raw 0xFFF1 signed LE).
    /// Expected: -1.5 °C, 185 lux, 51 %, 1019 µS/cm
    static let liveSubZero = Data([
        0xF1, 0xFF, 3, 185, 0, 0, 0, 51, 251, 3, 2, 60, 0, 251, 52, 155
    ])

    // MARK: - Historical entry (characteristic 00001a11)
    //
    // Wire format (>= 14 bytes):
    //   timestamp UInt32 LE seconds-since-boot (0..3) | temperature Int16 LE x10 (4..5)
    //   | skip (6) | brightness UInt32 LE (7..10) | moisture UInt8 (11)
    //   | conductivity UInt16 LE (12..13)

    /// Builds a history entry in the device wire format.
    /// `temperatureX10` takes the signed raw value, e.g. -15 for -1.5 °C.
    static func historyEntry(timestamp: UInt32,
                             temperatureX10: Int16,
                             brightness: UInt32,
                             moisture: UInt8,
                             conductivity: UInt16) -> Data {
        var data = Data()
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: temperatureX10.littleEndian) { data.append(contentsOf: $0) }
        data.append(0x00) // skipped byte between temperature and brightness
        withUnsafeBytes(of: brightness.littleEndian) { data.append(contentsOf: $0) }
        data.append(moisture)
        withUnsafeBytes(of: conductivity.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Firmware/battery (characteristic 00001a02)
    //
    // Wire format (7 bytes): battery UInt8 (0) | skip (1) | firmware ASCII (2..6)

    /// SYNTHETIC: 80 % battery, firmware "3.2.9" (a common FlowerCare version)
    static let firmwareAndBattery = Data([0x50, 0x2A]) + "3.2.9".data(using: .ascii)!

    // MARK: - Device time (characteristic 00001a12)
    //
    // Wire format (4 bytes): seconds since device boot, UInt32 LE

    /// SYNTHETIC: 10000 seconds since boot
    static let deviceTime10000 = Data([0x10, 0x27, 0x00, 0x00])

    // MARK: - History metadata (read on 00001a11 after 0xA00000)
    //
    // Wire format (16 bytes): entry count UInt16 LE (0..1) | unknown (2..15)

    static func historyMetadata(entryCount: UInt16) -> Data {
        var data = Data()
        withUnsafeBytes(of: entryCount.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0x00, count: 14))
        return data
    }
}
