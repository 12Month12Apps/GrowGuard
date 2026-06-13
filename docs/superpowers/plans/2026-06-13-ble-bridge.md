# BLE Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let GrowGuard (iOS Simulator or Mac) connect to FlowerCareSim on the same machine over a localhost socket, exercising the real connection/history-sync stack without a Bluetooth radio.

**Architecture:** A debug-only alternate implementation of GrowGuard's existing `BLECentral`/`BLEPeripheralLink` seam forwards requests over TCP localhost to a `BridgeServer` in FlowerCareSim, which drives the same `SensorBrain`s the radio path uses. A new `DeviceDiscovery` seam bridges the Add Device flow. The real BLE path is untouched and the bridge is inert unless `GROWGUARD_BLE_BRIDGE` is set.

**Tech Stack:** Swift, Network.framework (`NWConnection`/`NWListener`), Codable JSON over newline-framed TCP, XCTest. Xcode targets edited via the `xcodeproj` Ruby gem.

---

## File structure

Shared (added to **both** GrowGuard and FlowerCareSim targets), pure types:
- `GrowGuard/BLE/BridgeProtocol.swift` — `BridgeMessage` enum + `BridgeCodec` (encode/decode + newline framing). Not `#if DEBUG` (inert data types).

GrowGuard, production refactor:
- `GrowGuard/AddDevice/DeviceDiscovery.swift` — `DiscoveredDevice` + `DeviceDiscovery` protocol + `CoreBluetoothDeviceDiscovery` (wraps `AddDeviceBLE`).
- Modify `GrowGuard/AddDevice/AddDeviceViewModel.swift`, `AddDeviceView.swift`, `Details/AddDeviceDetails.swift` (`CBPeripheral` → `DiscoveredDevice`).

GrowGuard, debug-only (`#if DEBUG`):
- `GrowGuard/BLE/Bridge/BLEBridgeConfig.swift` — env-var config.
- `GrowGuard/BLE/Bridge/BridgeChannel.swift` — `BridgeChannel` protocol + `NWBridgeChannel`.
- `GrowGuard/BLE/Bridge/BridgeBLECentral.swift` — `BridgeBLECentral` + `BridgeBLEPeripheralLink`.
- `GrowGuard/BLE/Bridge/BridgeDeviceDiscovery.swift` — bridge discovery.
- Modify `GrowGuard/BLE/ConnectionPoolManager.swift:87-109` (pick bridge central).

FlowerCareSim:
- `FlowerCareSim/Bridge/BridgeServerCore.swift` — pure request→events against a brain.
- `FlowerCareSim/Bridge/BridgeServer.swift` — `NWListener` wiring.
- Modify `FlowerCareSim/App/SimulatorViewModel.swift`, `App/ContentView.swift` (Bridge UI).

Tests:
- `FlowerCareSimTests/BridgeProtocolTests.swift`, `BridgeServerCoreTests.swift`.
- `GrowGuardTests/BLE/BridgeBLECentralTests.swift`.

---

## Task 1: Wire protocol (`BridgeMessage` + `BridgeCodec`)

**Files:**
- Create: `GrowGuard/BLE/BridgeProtocol.swift`
- Test: `FlowerCareSimTests/BridgeProtocolTests.swift`
- Project: add `BridgeProtocol.swift` to GrowGuard + FlowerCareSim targets; add test to FlowerCareSimTests.

- [ ] **Step 1: Write `BridgeProtocol.swift`**

```swift
//  BridgeProtocol.swift — shared wire format for the debug BLE bridge.
import Foundation

/// One framed message on the bridge socket. `req*` = central→sim,
/// everything else = sim→central. UUIDs and payloads are strings so the JSON
/// stays human-readable and diffable, like the recording format.
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

/// Newline-delimited JSON framing.
enum BridgeCodec {
    static func encode(_ message: BridgeMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0a) // '\n'
        return data
    }

    /// Splits a buffer on newlines; returns decoded messages and the
    /// unconsumed remainder (a partial line).
    static func decode(appending newData: Data, to buffer: inout Data) -> [BridgeMessage] {
        buffer.append(newData)
        var messages: [BridgeMessage] = []
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            if let message = try? JSONDecoder().decode(BridgeMessage.self, from: Data(line)) {
                messages.append(message)
            }
        }
        return messages
    }
}
```

- [ ] **Step 2: Write failing tests `BridgeProtocolTests.swift`**

```swift
import XCTest
@testable import FlowerCareSim

final class BridgeProtocolTests: XCTestCase {
    func testRoundTripsEveryMessage() throws {
        let samples: [BridgeMessage] = [
            .scan, .stopScan, .connect(id: "A"), .cancel(id: "A"),
            .discoverServices(id: "A"), .discoverChars(id: "A", service: "1204"),
            .read(id: "A", char: "1a02"),
            .write(id: "A", char: "1a10", dataHex: "a00000", withResponse: true),
            .readRSSI(id: "A"),
            .state(value: 5),
            .discovered(id: "A", name: "Flower care", services: ["fe95"], rssi: -50),
            .connected(id: "A"), .disconnected(id: "A", errorCode: 7),
            .servicesDiscovered(id: "A", services: ["1204", "1206"]),
            .charsDiscovered(id: "A", service: "1204", chars: ["1a02"]),
            .valueUpdated(id: "A", char: "1a02", dataHex: "502a33", errorCode: nil),
            .writeConfirmed(id: "A", char: "1a10", errorCode: nil),
            .rssi(id: "A", value: -42),
        ]
        for message in samples {
            var buffer = Data()
            let encoded = try BridgeCodec.encode(message)
            XCTAssertEqual(encoded.last, 0x0a, "frame ends in newline")
            let decoded = BridgeCodec.decode(appending: encoded, to: &buffer)
            XCTAssertEqual(decoded, [message])
            XCTAssertTrue(buffer.isEmpty, "no remainder after a full frame")
        }
    }

    func testHandlesSplitAndConcatenatedFrames() throws {
        var buffer = Data()
        let a = try BridgeCodec.encode(.connect(id: "A"))
        let b = try BridgeCodec.encode(.read(id: "A", char: "1a11"))
        // deliver a partial first frame, then the rest + a whole second frame
        XCTAssertEqual(BridgeCodec.decode(appending: a.prefix(3), to: &buffer), [])
        let rest = a.suffix(from: a.index(a.startIndex, offsetBy: 3))
        let decoded = BridgeCodec.decode(appending: Data(rest) + b, to: &buffer)
        XCTAssertEqual(decoded, [.connect(id: "A"), .read(id: "A", char: "1a11")])
    }
}
```

- [ ] **Step 3: Add files to targets**

```bash
ruby -e '
require "xcodeproj"; p = Xcodeproj::Project.open("GrowGuard.xcodeproj")
gg = p.targets.find{|t| t.name=="GrowGuard"}; sim = p.targets.find{|t| t.name=="FlowerCareSim"}
simtests = p.targets.find{|t| t.name=="FlowerCareSimTests"}
proto = p.main_group.new_group("BridgeShared").new_reference("GrowGuard/BLE/BridgeProtocol.swift")
gg.source_build_phase.add_file_reference(proto); sim.source_build_phase.add_file_reference(proto)
tref = p.main_group.find_subpath("FlowerCareSimTests", true).new_reference("FlowerCareSimTests/BridgeProtocolTests.swift")
simtests.source_build_phase.add_file_reference(tref)
p.save; puts "wired task1"
'
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `xcodebuild test -scheme FlowerCareSim -destination 'platform=macOS' -only-testing:FlowerCareSimTests/BridgeProtocolTests 2>&1 | grep -E "Executed|passed|failed"`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit** — `git commit -m "BLE bridge: wire protocol + codec"`

---

## Task 2: `BridgeServerCore` (sim request handling, pure)

**Files:**
- Create: `FlowerCareSim/Bridge/BridgeServerCore.swift`
- Test: `FlowerCareSimTests/BridgeServerCoreTests.swift`

The core maps an inbound `BridgeMessage` request to the outbound events the sim
should emit, given the active brain and the sim's fixed GATT identity. No
sockets. The sim's GATT mirrors `SimulatedPeripheral`: services `1204`
(`1a00`/`1a01`/`1a02`) and `1206` (`1a10`/`1a11`/`1a12`), no auth char.

- [ ] **Step 1: Write `BridgeServerCore.swift`**

```swift
import Foundation
import CoreBluetooth

/// Translates bridge requests into the events a FlowerCare would produce,
/// using the active SensorBrain. Pure: returns events instead of writing a
/// socket, so it's unit-testable. `.silent` read outcomes return no event
/// (the app times out), matching the radio path.
final class BridgeServerCore {
    static let deviceID = "FACE0001-0000-0000-0000-00000000FACE"
    static let deviceName = "Flower care"

    var brain: SensorBrain

    init(brain: SensorBrain) { self.brain = brain }

    private let gatt: [String: [String]] = [
        dataServiceUUID.uuidString: [
            deviceModeChangeCharacteristicUUID.uuidString,
            realTimeSensorValuesCharacteristicUUID.uuidString,
            firmwareVersionCharacteristicUUID.uuidString,
        ],
        historyServiceUUID.uuidString: [
            historyControlCharacteristicUUID.uuidString,
            historicalSensorValuesCharacteristicUUID.uuidString,
            deviceTimeCharacteristicUUID.uuidString,
        ],
    ]

    /// Returns the events to send back for one request.
    func handle(_ request: BridgeMessage) -> [BridgeMessage] {
        let id = Self.deviceID
        switch request {
        case .scan:
            return [.discovered(id: id, name: Self.deviceName,
                                services: [flowerCareServiceUUID.uuidString], rssi: -50)]
        case .stopScan:
            return []
        case .connect:
            return [.connected(id: id)]
        case .cancel:
            return [.disconnected(id: id, errorCode: nil)]
        case .discoverServices:
            return [.servicesDiscovered(id: id, services: Array(gatt.keys))]
        case let .discoverChars(_, service):
            let chars = gatt.first { $0.key.caseInsensitiveCompare(service) == .orderedSame }?.value ?? []
            return [.charsDiscovered(id: id, service: service, chars: chars)]
        case let .read(_, char):
            switch brain.read(CBUUID(string: char)) {
            case .value(let data):
                return [.valueUpdated(id: id, char: char, dataHex: data.hexEncodedString, errorCode: nil)]
            case .error:
                return [.valueUpdated(id: id, char: char, dataHex: nil, errorCode: 0)]
            case .silent:
                return [] // no response; the app's per-entry timeout fires
            }
        case let .write(_, char, dataHex, withResponse):
            let outcome = brain.write(CBUUID(string: char), payload: Data(hexEncoded: dataHex) ?? Data())
            guard withResponse else { return [] }
            switch outcome {
            case .success: return [.writeConfirmed(id: id, char: char, errorCode: nil)]
            case .error, .silent: return [.writeConfirmed(id: id, char: char, errorCode: 0)]
            }
        case .readRSSI:
            return [.rssi(id: id, value: -50)]
        default:
            return []
        }
    }
}
```

- [ ] **Step 2: Write failing tests `BridgeServerCoreTests.swift`**

```swift
import XCTest
import CoreBluetooth
@testable import FlowerCareSim

final class BridgeServerCoreTests: XCTestCase {
    private func loadBrain() throws -> ReplayBrain {
        let bundle = Bundle(for: BridgeServerCoreTests.self)
        let url = try XCTUnwrap(bundle.urls(forResourcesWithExtension: "json", subdirectory: nil)?
            .first { $0.lastPathComponent.contains("synthetic") })
        return ReplayBrain(recording: try RecordingStore.load(from: url))
    }

    func testDiscoveryAndGatt() throws {
        let core = BridgeServerCore(brain: try loadBrain())
        XCTAssertEqual(core.handle(.scan),
                       [.discovered(id: BridgeServerCore.deviceID, name: "Flower care",
                                    services: [flowerCareServiceUUID.uuidString], rssi: -50)])
        XCTAssertEqual(core.handle(.connect(id: "x")), [.connected(id: BridgeServerCore.deviceID)])
        if case let .servicesDiscovered(_, services) = core.handle(.discoverServices(id: "x")).first {
            XCTAssertEqual(Set(services), [dataServiceUUID.uuidString, historyServiceUUID.uuidString])
        } else { XCTFail("expected servicesDiscovered") }
    }

    func testReadServesBrainValue() throws {
        let core = BridgeServerCore(brain: try loadBrain())
        let events = core.handle(.read(id: "x", char: firmwareVersionCharacteristicUUID.uuidString))
        XCTAssertEqual(events, [.valueUpdated(id: BridgeServerCore.deviceID,
                                              char: firmwareVersionCharacteristicUUID.uuidString,
                                              dataHex: "502a332e322e39", errorCode: nil)])
    }

    func testSilentFaultEmitsNoEvent() throws {
        let fault = FaultBrain(wrapping: LiveBrain())
        fault.fault = .silent
        let core = BridgeServerCore(brain: fault)
        core.handle(.write(id: "x", char: historyControlCharacteristicUUID.uuidString, dataHex: "a10000", withResponse: true))
        XCTAssertEqual(core.handle(.read(id: "x", char: historicalSensorValuesCharacteristicUUID.uuidString)), [])
    }
}
```

- [ ] **Step 3: Add files to targets** (FlowerCareSim + FlowerCareSimTests) via the gem, same pattern as Task 1 Step 3.

- [ ] **Step 4: Run tests, expect PASS** (`-only-testing:FlowerCareSimTests/BridgeServerCoreTests`).

- [ ] **Step 5: Commit** — `"BLE bridge: sim-side request core"`

---

## Task 3: `BridgeServer` (NWListener) + sim UI

**Files:**
- Create: `FlowerCareSim/Bridge/BridgeServer.swift`
- Modify: `FlowerCareSim/App/SimulatorViewModel.swift`, `App/ContentView.swift`

No unit test (socket glue); verified in the end-to-end manual check.

- [ ] **Step 1: Write `BridgeServer.swift`** — `NWListener` on the configured
  port; for each accepted `NWConnection`, receive bytes, feed
  `BridgeCodec.decode` into a buffer, pass each request to a `BridgeServerCore`,
  and send back each event via `BridgeCodec.encode`. Expose `@Published var
  isListening`, `port`, `connectedClient`. Reuse the view model's active brain
  (set `core.brain` whenever the mode changes). Log each request/event as a
  `TrafficEvent` (`.read`/`.write`/`.response`/`.info`).

```swift
import Foundation
import Network

@MainActor
final class BridgeServer: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var connectedClient: String?
    var port: UInt16 = 8765
    var onEvent: ((TrafficEvent) -> Void)?

    var brain: SensorBrain { didSet { core.brain = brain } }
    private lazy var core = BridgeServerCore(brain: brain)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()

    init(brain: SensorBrain) { self.brain = brain }

    func start() {
        stop()
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.isListening = true }
                    if case .failed = state { self?.isListening = false }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            onEvent?(TrafficEvent(.info, note: "Bridge listening on 127.0.0.1:\(port)"))
        } catch {
            onEvent?(TrafficEvent(.warning, note: "Bridge failed to listen: \(error.localizedDescription)"))
        }
    }

    func stop() {
        connection?.cancel(); listener?.cancel()
        connection = nil; listener = nil
        isListening = false; connectedClient = nil; buffer.removeAll()
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        connectedClient = "\(conn.endpoint)"
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in if case .cancelled = state { self?.connectedClient = nil } }
        }
        conn.start(queue: .main)
        receive(on: conn)
        onEvent?(TrafficEvent(.info, note: "Bridge client connected"))
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    for request in BridgeCodec.decode(appending: data, to: &self.buffer) {
                        self.process(request, on: conn)
                    }
                }
                if isComplete { self.connectedClient = nil } else { self.receive(on: conn) }
            }
        }
    }

    private func process(_ request: BridgeMessage, on conn: NWConnection) {
        logRequest(request)
        for event in core.handle(request) {
            logEvent(event)
            if let data = try? BridgeCodec.encode(event) {
                conn.send(content: data, completion: .idempotent)
            }
        }
    }

    private func logRequest(_ m: BridgeMessage) { /* map to TrafficEvent(.read/.write/.info) */ }
    private func logEvent(_ m: BridgeMessage) { /* map to TrafficEvent(.response/.info) */ }
}
```

- [ ] **Step 2: Add `BridgeServer` to `SimulatorViewModel`** — own a
  `BridgeServer(brain: live)`, point `onEvent` at the same `append`, and update
  `bridge.brain` inside `applyMode()` alongside `peripheral.brain`. Add
  `@Published var bridgeEnabled` / `bridgePort` and `startBridge()/stopBridge()`.

- [ ] **Step 3: Add a Bridge section to `ContentView`'s control panel** — a
  toggle (start/stop), a port field, and `isListening` / `connectedClient`
  status text.

- [ ] **Step 4: Add `BridgeServer.swift` to FlowerCareSim target** via the gem.

- [ ] **Step 5: Build the sim** — `xcodebuild build -scheme FlowerCareSim -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3` → `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit** — `"BLE bridge: sim NWListener server + UI"`

---

## Task 4: GrowGuard `BridgeChannel` + `NWBridgeChannel` + `BLEBridgeConfig`

**Files:**
- Create: `GrowGuard/BLE/Bridge/BLEBridgeConfig.swift`, `GrowGuard/BLE/Bridge/BridgeChannel.swift`
- All `#if DEBUG`.

- [ ] **Step 1: `BLEBridgeConfig.swift`**

```swift
#if DEBUG
import Foundation

/// Reads GROWGUARD_BLE_BRIDGE=host:port once. When unset, the bridge is off and
/// the app uses the real CoreBluetooth transport.
enum BLEBridgeConfig {
    static let endpoint: (host: String, port: UInt16)? = {
        guard let raw = ProcessInfo.processInfo.environment["GROWGUARD_BLE_BRIDGE"] else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }()
    static var isEnabled: Bool { endpoint != nil }
}
#endif
```

- [ ] **Step 2: `BridgeChannel.swift`** — protocol + Network.framework impl.

```swift
#if DEBUG
import Foundation
import Network

/// Send/receive of BridgeMessages, abstracted so BridgeBLECentral is testable
/// with a fake. onReceive/onState are invoked on the main queue.
protocol BridgeChannel: AnyObject {
    var onReceive: ((BridgeMessage) -> Void)? { get set }
    var onReady: (() -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func connect()
    func send(_ message: BridgeMessage)
}

final class NWBridgeChannel: BridgeChannel {
    var onReceive: ((BridgeMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private var buffer = Data()

    init(host: String, port: UInt16) {
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.onReady?(); self?.receive()
                case .failed, .cancelled: self?.onClosed?()
                default: break
                }
            }
        }
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
                    for message in BridgeCodec.decode(appending: data, to: &self.buffer) { self.onReceive?(message) }
                }
                if isComplete { self.onClosed?() } else { self.receive() }
            }
        }
    }
}
#endif
```

- [ ] **Step 3: Add both files to GrowGuard target** via the gem.
- [ ] **Step 4: Build GrowGuard** for `generic/platform=iOS Simulator` Debug → succeeds.
- [ ] **Step 5: Commit** — `"BLE bridge: GrowGuard channel + config"`

---

## Task 5: `BridgeBLECentral` + `BridgeBLEPeripheralLink`

**Files:**
- Create: `GrowGuard/BLE/Bridge/BridgeBLECentral.swift` (`#if DEBUG`)
- Test: `GrowGuardTests/BLE/BridgeBLECentralTests.swift`

`BridgeBLECentral` implements `BLECentral`; `BridgeBLEPeripheralLink` implements
`BLEPeripheralLink`. Both translate seam calls into `BridgeMessage`s on a
`BridgeChannel` and route inbound events to the right delegate. One link per
UUID; `retrievePeripherals` vends a link immediately.

- [ ] **Step 1: Write `BridgeBLECentral.swift`**

```swift
#if DEBUG
import Foundation
import CoreBluetooth

final class BridgeBLECentral: NSObject, BLECentral {
    weak var centralDelegate: BLECentralDelegate?
    private(set) var state: CBManagerState = .unknown
    private let channel: BridgeChannel
    private var links: [String: BridgeBLEPeripheralLink] = [:]

    init(channel: BridgeChannel) {
        self.channel = channel
        super.init()
        channel.onReady = { [weak self] in
            self?.state = .poweredOn
            self.map { $0.centralDelegate?.central($0, didUpdateState: .poweredOn) }
        }
        channel.onClosed = { [weak self] in
            self?.state = .poweredOff
            self.map { $0.centralDelegate?.central($0, didUpdateState: .poweredOff) }
        }
        channel.onReceive = { [weak self] in self?.handle($0) }
        channel.connect()
    }

    private func link(for id: String) -> BridgeBLEPeripheralLink {
        if let existing = links[id] { return existing }
        let link = BridgeBLEPeripheralLink(id: id, channel: channel)
        links[id] = link
        return link
    }

    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BLEPeripheralLink] {
        identifiers.map { link(for: $0.uuidString) }
    }
    func connect(_ peripheral: BLEPeripheralLink, options: [String: Any]?) {
        channel.send(.connect(id: peripheral.identifier.uuidString))
    }
    func cancelConnection(_ peripheral: BLEPeripheralLink) {
        channel.send(.cancel(id: peripheral.identifier.uuidString))
    }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        channel.send(.scan)
    }
    func stopScan() { channel.send(.stopScan) }

    private func handle(_ message: BridgeMessage) {
        switch message {
        case let .discovered(id, name, services, rssi):
            let l = link(for: id); l.cachedName = name
            centralDelegate?.central(self, didDiscover: l,
                advertisementData: [CBAdvertisementDataLocalNameKey: name as Any], rssi: NSNumber(value: rssi))
        case let .connected(id):
            let l = link(for: id); l.bridgeState = .connected
            centralDelegate?.central(self, didConnect: l)
        case let .disconnected(id, errorCode):
            let l = link(for: id); l.bridgeState = .disconnected
            centralDelegate?.central(self, didDisconnect: l, error: errorCode.map { Self.cbError($0) })
        case let .servicesDiscovered(id, services):
            link(for: id).linkDelegate?.peripheralLink(link(for: id),
                didDiscoverServices: services.map { CBUUID(string: $0) }, error: nil)
        case let .charsDiscovered(id, service, chars):
            link(for: id).linkDelegate?.peripheralLink(link(for: id),
                didDiscoverCharacteristics: chars.map { CBUUID(string: $0) },
                forService: CBUUID(string: service), error: nil)
        case let .valueUpdated(id, char, dataHex, errorCode):
            link(for: id).linkDelegate?.peripheralLink(link(for: id),
                didUpdateValueFor: CBUUID(string: char),
                value: dataHex.flatMap { Data(hexEncoded: $0) }, error: errorCode.map { Self.cbError($0) })
        case let .writeConfirmed(id, char, errorCode):
            link(for: id).linkDelegate?.peripheralLink(link(for: id),
                didWriteValueFor: CBUUID(string: char), error: errorCode.map { Self.cbError($0) })
        case let .rssi(id, value):
            link(for: id).linkDelegate?.peripheralLink(link(for: id), didReadRSSI: value, error: nil)
        case let .state(value):
            let s = CBManagerState(rawValue: value) ?? .unknown
            state = s; centralDelegate?.central(self, didUpdateState: s)
        default: break
        }
    }

    private static func cbError(_ code: Int) -> NSError {
        NSError(domain: CBErrorDomain, code: code)
    }
}

final class BridgeBLEPeripheralLink: BLEPeripheralLink {
    let id: String
    private let channel: BridgeChannel
    weak var linkDelegate: BLEPeripheralLinkDelegate?
    var cachedName: String?
    var bridgeState: CBPeripheralState = .disconnected

    init(id: String, channel: BridgeChannel) { self.id = id; self.channel = channel }

    var identifier: UUID { UUID(uuidString: id) ?? UUID() }
    var name: String? { cachedName }
    var state: CBPeripheralState { bridgeState }

    func discoverServices() { channel.send(.discoverServices(id: id)) }
    func discoverCharacteristics(forService s: CBUUID) { channel.send(.discoverChars(id: id, service: s.uuidString)) }
    func readValue(forCharacteristic c: CBUUID) { channel.send(.read(id: id, char: c.uuidString)) }
    func writeValue(_ data: Data, forCharacteristic c: CBUUID, type: CBCharacteristicWriteType) {
        channel.send(.write(id: id, char: c.uuidString, dataHex: data.hexEncodedString, withResponse: type == .withResponse))
    }
    func readRSSI() { channel.send(.readRSSI(id: id)) }
}
```

(Note: `identifier` must be stable; the sim's fixed `FACE…` UUID parses, so
saved devices keep a consistent identity.)

- [ ] **Step 2: Write failing tests `BridgeBLECentralTests.swift`** — drive a
  `FakeBridgeChannel` (records sent messages, lets the test inject received
  ones) and assert the delegate callbacks + outbound messages.

```swift
#if DEBUG
import XCTest
import CoreBluetooth
@testable import GrowGuard

final class FakeBridgeChannel: BridgeChannel {
    var onReceive: ((BridgeMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: (() -> Void)?
    private(set) var sent: [BridgeMessage] = []
    func connect() { onReady?() }
    func send(_ message: BridgeMessage) { sent.append(message) }
    func inject(_ message: BridgeMessage) { onReceive?(message) }
}

final class BridgeBLECentralTests: XCTestCase {
    final class DelegateSpy: NSObject, BLECentralDelegate {
        var discovered: [BLEPeripheralLink] = []; var connected: [BLEPeripheralLink] = []
        func central(_ c: BLECentral, didUpdateState s: CBManagerState) {}
        func central(_ c: BLECentral, didDiscover p: BLEPeripheralLink, advertisementData: [String:Any], rssi: NSNumber) { discovered.append(p) }
        func central(_ c: BLECentral, didConnect p: BLEPeripheralLink) { connected.append(p) }
        func central(_ c: BLECentral, didDisconnect p: BLEPeripheralLink, error: Error?) {}
        func central(_ c: BLECentral, didFailToConnect p: BLEPeripheralLink, error: Error?) {}
        func central(_ c: BLECentral, willRestoreState p: [BLEPeripheralLink]) {}
    }

    func testScanSurfacesDiscoveredDevice() {
        let chan = FakeBridgeChannel(); let central = BridgeBLECentral(channel: chan)
        let spy = DelegateSpy(); central.centralDelegate = spy
        central.scanForPeripherals(withServices: nil, options: nil)
        XCTAssertEqual(chan.sent.last, .scan)
        chan.inject(.discovered(id: "FACE0001-0000-0000-0000-00000000FACE", name: "Flower care", services: ["fe95"], rssi: -50))
        XCTAssertEqual(spy.discovered.first?.name, "Flower care")
    }

    func testReadForwardsAndDeliversValue() {
        let chan = FakeBridgeChannel(); let central = BridgeBLECentral(channel: chan)
        let link = central.retrievePeripherals(withIdentifiers: [UUID(uuidString: "FACE0001-0000-0000-0000-00000000FACE")!]).first!
        final class LinkSpy: BLEPeripheralLinkDelegate {
            var value: Data?
            func peripheralLink(_ l: BLEPeripheralLink, didDiscoverServices s: [CBUUID], error: Error?) {}
            func peripheralLink(_ l: BLEPeripheralLink, didDiscoverCharacteristics c: [CBUUID], forService s: CBUUID, error: Error?) {}
            func peripheralLink(_ l: BLEPeripheralLink, didUpdateValueFor c: CBUUID, value: Data?, error: Error?) { self.value = value }
            func peripheralLink(_ l: BLEPeripheralLink, didWriteValueFor c: CBUUID, error: Error?) {}
            func peripheralLink(_ l: BLEPeripheralLink, didReadRSSI rssi: Int, error: Error?) {}
        }
        let spy = LinkSpy(); link.linkDelegate = spy
        link.readValue(forCharacteristic: firmwareVersionCharacteristicUUID)
        XCTAssertEqual(chan.sent.last, .read(id: link.identifier.uuidString, char: firmwareVersionCharacteristicUUID.uuidString))
        chan.inject(.valueUpdated(id: link.identifier.uuidString, char: firmwareVersionCharacteristicUUID.uuidString, dataHex: "502a33", errorCode: nil))
        XCTAssertEqual(spy.value, Data(hexEncoded: "502a33"))
    }
}
#endif
```

- [ ] **Step 3: Add both files to GrowGuard / GrowGuardTests targets** via the gem.
- [ ] **Step 4: Run GrowGuardTests bridge tests** → PASS.
- [ ] **Step 5: Commit** — `"BLE bridge: GrowGuard central + link"`

---

## Task 6: Inject the bridge central into `ConnectionPoolManager`

**Files:** Modify `GrowGuard/BLE/ConnectionPoolManager.swift:90-102`

- [ ] **Step 1: Edit the `else` branch**

```swift
} else {
    #if DEBUG
    if let endpoint = BLEBridgeConfig.endpoint {
        self.central = BridgeBLECentral(channel: NWBridgeChannel(host: endpoint.host, port: endpoint.port))
        self.scheduler = scheduler
        self.now = now
        super.init()
        self.central.centralDelegate = self
        AppLogger.ble.info("🔌 BLE bridge active → \(endpoint.host):\(endpoint.port)")
        return
    }
    #endif
    let options: [String: Any] = [
        CBCentralManagerOptionRestoreIdentifierKey: "pro.veit.GrowGuard.centralManager",
        CBCentralManagerOptionShowPowerAlertKey: true
    ]
    self.central = RecordingBLECentral(wrapping: CoreBluetoothCentral(options: options))
}
```

(Adjust so `scheduler`/`now`/`super.init` run exactly once — simplest is to set
`self.central` in both branches and keep the shared tail. Refactor the init to
compute `central` first, then assign + `super.init()` once.)

- [ ] **Step 2: Build GrowGuard (Debug, iOS Simulator)** → succeeds; run the full GrowGuardTests suite → still green.
- [ ] **Step 3: Commit** — `"BLE bridge: route ConnectionPool through bridge when enabled"`

---

## Task 7: `DiscoveredDevice` + `DeviceDiscovery` seam (onboarding refactor)

**Files:**
- Create: `GrowGuard/AddDevice/DeviceDiscovery.swift`
- Modify: `AddDeviceViewModel.swift`, `AddDeviceView.swift`, `Details/AddDeviceDetails.swift`

- [ ] **Step 1: `DeviceDiscovery.swift`**

```swift
import Foundation
import CoreBluetooth

/// A device seen during onboarding, decoupled from CoreBluetooth so the add
/// flow can be driven by the real scanner or the debug bridge.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String?
}

protocol DeviceDiscovery: AnyObject {
    var onState: ((CBManagerState) -> Void)? { get set }
    var onFound: ((DiscoveredDevice) -> Void)? { get set }
    func start()
    func stop()
}

/// Real scanner: wraps the existing CBCentralManager-based AddDeviceBLE.
final class CoreBluetoothDeviceDiscovery: DeviceDiscovery {
    var onState: ((CBManagerState) -> Void)?
    var onFound: ((DiscoveredDevice) -> Void)?
    private var ble: AddDeviceBLE?

    func start() {
        ble = AddDeviceBLE(
            foundDevice: { [weak self] peripheral in
                self?.onFound?(DiscoveredDevice(id: peripheral.identifier, name: peripheral.name))
            },
            stateChanged: { [weak self] state in self?.onState?(state) }
        )
        ble?.startScanning()
    }
    func stop() { ble?.stopScanning(); ble = nil }
}
```

- [ ] **Step 2: Migrate `AddDeviceViewModel`** — `devices: [DiscoveredDevice]`,
  `addDevice: DiscoveredDevice?`; replace direct `AddDeviceBLE` use with a
  `DeviceDiscovery` (defaulting to `CoreBluetoothDeviceDiscovery()`, injectable);
  `addToList(_ device: DiscoveredDevice)` dedupes on `id`. Wire `onFound`/
  `onState` to the existing main-actor handlers.

- [ ] **Step 3: Migrate `AddDeviceView`** — `ForEach(viewModel.devices, id: \.id)`,
  `DeviceRow.device: DiscoveredDevice`, use `device.name`/`device.id`.

- [ ] **Step 4: Migrate `AddDeviceDetails`** — navigation case
  `deviceDetails(DiscoveredDevice, suggestedName:)`, the view's `device:
  DiscoveredDevice`, and the save reads `device.id.uuidString`/`device.name`.

- [ ] **Step 5: Add `DeviceDiscovery.swift` to GrowGuard target**; build Debug
  (iOS Simulator) → succeeds.

- [ ] **Step 6: Commit** — `"Add Device: DiscoveredDevice/DeviceDiscovery seam (no behavior change)"`

---

## Task 8: `BridgeDeviceDiscovery` + inject into onboarding

**Files:**
- Create: `GrowGuard/BLE/Bridge/BridgeDeviceDiscovery.swift` (`#if DEBUG`)
- Modify: `AddDeviceViewModel.swift` (pick bridge when enabled)

- [ ] **Step 1: `BridgeDeviceDiscovery.swift`**

```swift
#if DEBUG
import Foundation
import CoreBluetooth

/// Drives onboarding over the bridge socket: `scan` → `discovered`.
final class BridgeDeviceDiscovery: DeviceDiscovery {
    var onState: ((CBManagerState) -> Void)?
    var onFound: ((DiscoveredDevice) -> Void)?
    private let channel: BridgeChannel

    init(channel: BridgeChannel) {
        self.channel = channel
        channel.onReady = { [weak self] in self?.onState?(.poweredOn); self?.channel.send(.scan) }
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
```

- [ ] **Step 2: In `AddDeviceViewModel.startScanningIfNeeded`**, choose the
  discovery impl:

```swift
#if DEBUG
let discovery: DeviceDiscovery = BLEBridgeConfig.endpoint.map {
    BridgeDeviceDiscovery(channel: NWBridgeChannel(host: $0.host, port: $0.port))
} ?? CoreBluetoothDeviceDiscovery()
#else
let discovery: DeviceDiscovery = CoreBluetoothDeviceDiscovery()
#endif
```

- [ ] **Step 3: Add file to GrowGuard target**; build Debug → succeeds.
- [ ] **Step 4: Commit** — `"BLE bridge: bridge-backed Add Device discovery"`

---

## Task 9: End-to-end manual verification + docs

- [ ] **Step 1:** Run FlowerCareSim (My Mac), enable Bridge (port 8765), load the
  bundled synthetic recording.
- [ ] **Step 2:** Edit the GrowGuard scheme → Run → Arguments → Environment:
  `GROWGUARD_BLE_BRIDGE = 127.0.0.1:8765`. Run GrowGuard on an iOS Simulator.
- [ ] **Step 3:** Add Device → "Flower care" appears → add it. Confirm the sim
  traffic log shows `scan`/`discovered`.
- [ ] **Step 4:** Open the device → history sync runs → completes with 5 entries;
  sim log shows firmware → `a00000` → time → `3c` → metadata → per-entry reads.
- [ ] **Step 5:** Switch sim to Fault: silent @ entry 2 → reconnect/refresh →
  GrowGuard skips entry 2 and still finishes.
- [ ] **Step 6:** Update `FlowerCareSim/README.md` with a "Single-machine bridge"
  section (env var, steps). Commit.
- [ ] **Step 7 (regression):** Build & run the real Add Device path once on
  hardware (or confirm the unit/build coverage) to ensure the `DiscoveredDevice`
  refactor didn't break onboarding.

---

## Self-review notes

- **Spec coverage:** wire protocol (T1), sim core+server+UI (T2/T3), GrowGuard
  channel/config (T4), central/link (T5), pool injection (T6), onboarding
  refactor (T7), bridge discovery (T8), manual e2e + docs (T9). All spec
  sections covered.
- **Type consistency:** `BridgeMessage` cases, `BridgeServerCore.deviceID`,
  `DiscoveredDevice {id,name}`, `BridgeChannel` callbacks used identically across
  tasks.
- **Risk:** T7 touches onboarding — mitigated by keeping changes mechanical and
  the T9 regression check.
