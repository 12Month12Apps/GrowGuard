//
//  BLESessionRecorder.swift
//  GrowGuard
//
//  Sammelt BLE-Transport-Ereignisse pro Gerät und schreibt sie als JSON
//  nach Documents/BLERecordings. Aufzeichnung ist opt-in (Toggle im Debug-
//  Menü) und kostet ausgeschaltet praktisch nichts — die Decorators in
//  RecordingBLETransport.swift prüfen `isEnabled` pro Ereignis.
//
//  Threading: Delegate-Callbacks kommen in Produktion auf der Main Queue,
//  in Tests von beliebigen Threads — der Recorder ist Lock-geschützt.
//  Datei-Writes laufen auf einer Utility-Queue mit Snapshot-Kopien.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class BLESessionRecorder {

    static let shared = BLESessionRecorder()

    static let enabledDefaultsKey = "ble.sessionRecordingEnabled"
    static let recordingsDirectoryName = "BLERecordings"

    /// Sicherheitsgrenze gegen unbegrenzt wachsende Sessions
    /// (eine volle 3700-Entry-History sind ~8k Ereignisse)
    static let maxEventsPerSession = 100_000

    // MARK: - State

    private let lock = NSLock()
    private var enabled: Bool
    private var sessions: [UUID: Session] = [:]

    private let defaults: UserDefaults
    private let directory: URL
    private let writeQueue = DispatchQueue(label: "pro.veit.GrowGuard.bleRecorder", qos: .utility)

    private struct Session {
        let startedAt: Date
        let fileURL: URL
        var recording: BLESessionRecording
        var overflowLogged = false
    }

    // MARK: - Init

    /// Produktion nutzt `shared`; Tests injizieren eigene Defaults/Verzeichnisse.
    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Self.recordingsDirectoryName, isDirectory: true)

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushAllSessions()
        }
        #endif
    }

    // MARK: - Public API

    /// Opt-in Schalter, persistiert in UserDefaults. Ausschalten beendet
    /// und speichert alle laufenden Sessions.
    var isEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
            defaults.set(newValue, forKey: Self.enabledDefaultsKey)
            if !newValue {
                finishAllSessions()
            }
            AppLogger.ble.info("🎙️ BLE session recording \(newValue ? "enabled" : "disabled")")
        }
    }

    /// Zeichnet ein Ereignis für ein Gerät auf. Startet bei Bedarf eine neue
    /// Session. No-op wenn Aufzeichnung deaktiviert ist.
    /// Disconnects werden automatisch auf Platte gesichert (Crash-Toleranz),
    /// die Session bleibt aber offen — Reconnect-Verläufe gehören in EINE Datei.
    func record(_ event: BLESessionEvent, device: UUID, deviceName: String? = nil) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }

        var session = sessions[device] ?? startSession(device: device, deviceName: deviceName)
        if session.recording.deviceName == nil, let deviceName = deviceName {
            session.recording.deviceName = deviceName
        }

        if session.recording.events.count < Self.maxEventsPerSession {
            var stamped = event
            stamped.t = Date().timeIntervalSince(session.startedAt)
            session.recording.events.append(stamped)
        } else if !session.overflowLogged {
            session.overflowLogged = true
            AppLogger.ble.bleWarning("🎙️ Recording for \(device) hit the event cap, dropping further events")
        }
        sessions[device] = session

        let shouldFlush = event.type == .disconnected || event.type == .failedToConnect
        let snapshot = shouldFlush ? session : nil
        lock.unlock()

        if let snapshot = snapshot {
            write(snapshot)
        }
    }

    /// Zeichnet ein zentrales Ereignis (Bluetooth-State) in allen laufenden
    /// Sessions auf
    func recordCentralEvent(_ event: BLESessionEvent) {
        lock.lock()
        guard enabled, !sessions.isEmpty else {
            lock.unlock()
            return
        }
        for (device, var session) in sessions {
            var stamped = event
            stamped.t = Date().timeIntervalSince(session.startedAt)
            if session.recording.events.count < Self.maxEventsPerSession {
                session.recording.events.append(stamped)
                sessions[device] = session
            }
        }
        lock.unlock()
    }

    /// Beendet die Session eines Geräts und schreibt sie auf Platte
    func finishSession(device: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: device)
        lock.unlock()
        if let session = session {
            write(session)
        }
    }

    /// Beendet alle laufenden Sessions und schreibt sie auf Platte
    func finishAllSessions() {
        lock.lock()
        let finished = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for session in finished {
            write(session)
        }
    }

    /// Sichert alle laufenden Sessions, lässt sie aber offen
    /// (z.B. beim App-Background — Crash-Toleranz)
    func flushAllSessions() {
        lock.lock()
        let snapshots = Array(sessions.values)
        lock.unlock()
        for session in snapshots {
            write(session)
        }
    }

    /// Alle gespeicherten Recordings, neueste zuerst
    func listRecordings() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(BLESessionRecording.fileExtension) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    func deleteAllRecordings() {
        for url in listRecordings() {
            try? FileManager.default.removeItem(at: url)
        }
        AppLogger.ble.info("🗑️ Deleted all BLE session recordings")
    }

    /// Aktuelle Session eines Geräts (für Tests/Introspektion)
    func activeRecording(for device: UUID) -> BLESessionRecording? {
        lock.lock(); defer { lock.unlock() }
        return sessions[device]?.recording
    }

    /// Blockiert bis alle ausstehenden Datei-Writes abgeschlossen sind
    /// (Tests prüfen danach den Datei-Inhalt)
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    // MARK: - Private

    /// Muss unter `lock` aufgerufen werden
    private func startSession(device: UUID, deviceName: String?) -> Session {
        let startedAt = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let shortID = device.uuidString.prefix(8).lowercased()
        let fileName = "\(shortID)_\(formatter.string(from: startedAt)).\(BLESessionRecording.fileExtension)"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let session = Session(
            startedAt: startedAt,
            fileURL: directory.appendingPathComponent(fileName),
            recording: BLESessionRecording(
                deviceUUID: device.uuidString,
                deviceName: deviceName,
                appVersion: appVersion,
                recordedAt: startedAt,
                events: []
            )
        )
        sessions[device] = session
        AppLogger.ble.info("🎙️ Started BLE session recording for \(device) → \(fileName)")
        return session
    }

    private func write(_ session: Session) {
        let recording = session.recording
        let fileURL = session.fileURL
        let directory = self.directory
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(recording)
                try data.write(to: fileURL, options: .atomic)
                AppLogger.ble.info("🎙️ Saved BLE recording (\(recording.events.count) events) to \(fileURL.lastPathComponent)")
            } catch {
                AppLogger.ble.bleError("🎙️ Failed to write BLE recording: \(error.localizedDescription)")
            }
        }
    }
}
