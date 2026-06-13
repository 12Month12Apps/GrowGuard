//
//  BridgeDeviceDiscovery.swift
//  GrowGuard
//
//  Debug-only Add Device discovery over the bridge socket: on connect it sends
//  `scan` and surfaces the sim's `discovered` reply as a DiscoveredDevice, so
//  onboarding works on a single machine without a radio.
//

#if DEBUG
import Foundation
import CoreBluetooth

final class BridgeDeviceDiscovery: DeviceDiscovery {
    var onState: ((CBManagerState) -> Void)?
    var onFound: ((DiscoveredDevice) -> Void)?

    private let channel: BridgeChannel

    init(channel: BridgeChannel) {
        self.channel = channel
        channel.onReady = { [weak self] in
            self?.onState?(.poweredOn)
            self?.channel.send(.scan)
        }
        channel.onClosed = { [weak self] in
            self?.onState?(.poweredOff)
        }
        channel.onReceive = { [weak self] message in
            if case let .discovered(id, name, _, _) = message, let uuid = UUID(uuidString: id) {
                self?.onFound?(DiscoveredDevice(id: uuid, name: name))
            }
        }
    }

    func start() { channel.connect() }
    func stop() { channel.send(.stopScan) }
}
#endif
