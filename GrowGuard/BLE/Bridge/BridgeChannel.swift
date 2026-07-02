//
//  BridgeChannel.swift
//  GrowGuard
//
//  Debug-only: send/receive of BridgeMessages over the bridge socket,
//  abstracted behind a protocol so BridgeBLECentral / BridgeDeviceDiscovery are
//  unit-testable with a fake. Callbacks fire on the main queue.
//

#if DEBUG
import Foundation
import Network

protocol BridgeChannel: AnyObject {
    var onReceive: ((BridgeMessage) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func connect()
    func send(_ message: BridgeMessage)
}

/// Network.framework-backed channel: a single TCP connection to the sim.
final class NWBridgeChannel: BridgeChannel {
    var onReceive: ((BridgeMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private var buffer = Data()
    private var didReport = false
    private let endpointLabel: String

    init(host: String, port: UInt16) {
        endpointLabel = "\(host):\(port)"
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: .tcp)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .ready:
                    AppLogger.ble.bleConnection("🔌 Bridge channel ready (\(self.endpointLabel))")
                    self.onReady?()
                    self.receive()
                case .waiting(let error):
                    // Server not listening / wrong port → connection refused.
                    // Surfaced explicitly because a silent .waiting otherwise
                    // hangs forever with no device and no error in the UI.
                    AppLogger.ble.bleWarning("🔌 Bridge channel waiting (\(self.endpointLabel)): \(error.localizedDescription) — is FlowerCareSim's bridge started on this host:port?")
                case .failed(let error):
                    AppLogger.ble.bleError("🔌 Bridge channel failed (\(self.endpointLabel)): \(error.localizedDescription)")
                    if !self.didReport { self.didReport = true; self.onClosed?() }
                case .cancelled:
                    if !self.didReport { self.didReport = true; self.onClosed?() }
                default:
                    break
                }
            }
        }
        AppLogger.ble.bleConnection("🔌 Bridge channel connecting → \(endpointLabel)")
        connection.start(queue: .main)
    }

    func send(_ message: BridgeMessage) {
        guard let data = try? BridgeCodec.encode(message) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    for message in BridgeCodec.decode(appending: data, to: &self.buffer) {
                        self.onReceive?(message)
                    }
                }
                if isComplete {
                    if !self.didReport { self.didReport = true; self.onClosed?() }
                } else {
                    self.receive()
                }
            }
        }
    }
}
#endif
