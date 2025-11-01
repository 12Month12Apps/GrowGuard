# Konzept: Gleichzeitige Abfrage mehrerer Sensoren

## Aktuelle Situation

### Probleme
1. **Singleton-Pattern**: `FlowerCareManager.shared` kann nur ein Gerät zur Zeit verwalten
2. **Single Connection**: Nur ein `discoveredPeripheral` wird gespeichert
3. **Shared State**: Alle ViewModels nutzen den gleichen Manager
4. **CoreBluetooth Limitierungen**: Ein `CBCentralManager` pro Manager-Instanz

### Aktuelle Architektur
```
OverviewList/DeviceDetails
    ↓
FlowerCareManager.shared (Singleton)
    ↓
CBCentralManager → discoveredPeripheral (1 Gerät)
```

## Lösungsansätze

### Ansatz 1: Connection Pool Manager (EMPFOHLEN)

**Konzept**: Ein zentraler Manager verwaltet mehrere BLE-Verbindungen

#### Architektur
```
ConnectionPoolManager (Singleton)
    ↓
CBCentralManager (zentral, 1x)
    ↓
[DeviceConnection, DeviceConnection, DeviceConnection, ...]
       ↓              ↓                ↓
   Peripheral 1   Peripheral 2    Peripheral 3
```

#### Vorteile
✅ Apple-Best-Practice (1 CBCentralManager für die ganze App)
✅ Zentrale Verwaltung aller Verbindungen
✅ Einfaches State-Management
✅ Bessere Performance durch Connection Pooling
✅ Weniger Code-Änderungen in ViewModels

#### Nachteile
❌ Größerer Refactoring-Aufwand
❌ Komplexeres Design

#### Implementierung

**Neue Klassen:**

1. **`ConnectionPoolManager`** (Singleton)
   - Verwaltet einen `CBCentralManager`
   - Verwaltet Dictionary von `DeviceConnection` Objekten
   - Scannt nach mehreren Geräten gleichzeitig
   - Koordiniert Verbindungen

2. **`DeviceConnection`** (pro Gerät)
   - Kapselt ein `CBPeripheral`
   - Verwaltet Charakteristiken
   - Handhabt Authentifizierung
   - Published Sensor-Daten für ein spezifisches Gerät

3. **`BLECoordinator`** (Optional)
   - Priorisiert Operationen
   - Queue-Management
   - Verhindert Überlastung

**Datenfluss:**
```swift
// ViewModel Ebene
DeviceDetailsViewModel
    ↓
ConnectionPoolManager.shared.getConnection(for: deviceUUID)
    ↓
DeviceConnection (deviceUUID)
    ↓
.sensorDataPublisher
```

---

### Ansatz 2: Multi-Manager (NICHT EMPFOHLEN)

**Konzept**: Mehrere FlowerCareManager-Instanzen

#### Architektur
```
FlowerCareManager(device1) → CBCentralManager → Peripheral 1
FlowerCareManager(device2) → CBCentralManager → Peripheral 2
FlowerCareManager(device3) → CBCentralManager → Peripheral 3
```

#### Vorteile
✅ Minimaler Refactoring
✅ Isolation pro Gerät

#### Nachteile
❌ Verstößt gegen Apple Guidelines (mehrere CBCentralManager)
❌ Potenzielle Konflikte zwischen Managern
❌ Höherer Ressourcenverbrauch
❌ Komplexes Debugging

---

## Detailliertes Design - Ansatz 1

### Phase 1: Core-Struktur

#### 1.1 DeviceConnection.swift
```swift
import CoreBluetooth
import Combine

class DeviceConnection: NSObject, CBPeripheralDelegate {
    // Identifikation
    let deviceUUID: String
    private(set) var peripheral: CBPeripheral?

    // Connection State
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case authenticated
        case error(Error)
    }
    private let stateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    // Publishers
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()

    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        sensorDataSubject.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // BLE Charakteristiken
    private var characteristics: [String: CBCharacteristic] = [:]

    // Authentication
    private var isAuthenticated = false
    private let decoder = SensorDataDecoder()

    init(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        super.init()
    }

    func setPeripheral(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
    }

    // Weitere Methoden...
}
```

#### 1.2 ConnectionPoolManager.swift
```swift
import CoreBluetooth
import Combine

@MainActor
class ConnectionPoolManager: NSObject, CBCentralManagerDelegate {
    static let shared = ConnectionPoolManager()

    private var centralManager: CBCentralManager!

    // Connection Pool
    private var connections: [String: DeviceConnection] = [:]

    // Scanning State
    private var devicesToScan: Set<String> = []
    private var isScanning = false

    // Publishers
    private let scanningStateSubject = CurrentValueSubject<Bool, Never>(false)

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    /// Holt oder erstellt eine Verbindung für ein Gerät
    func getConnection(for deviceUUID: String) -> DeviceConnection {
        if let existing = connections[deviceUUID] {
            return existing
        }

        let connection = DeviceConnection(deviceUUID: deviceUUID)
        connections[deviceUUID] = connection
        return connection
    }

    /// Verbindet zu einem Gerät
    func connect(to deviceUUID: String) {
        let connection = getConnection(for: deviceUUID)

        // Prüfe ob bereits verbunden
        if case .connected = connection.connectionState {
            return
        }

        // Suche bekanntes Peripheral
        let uuid = UUID(uuidString: deviceUUID)!
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])

        if let peripheral = peripherals.first {
            connection.setPeripheral(peripheral)
            centralManager.connect(peripheral, options: nil)
        } else {
            // Starte Scan
            devicesToScan.insert(deviceUUID)
            startScanning()
        }
    }

    /// Trennt Verbindung zu einem Gerät
    func disconnect(from deviceUUID: String) {
        guard let connection = connections[deviceUUID],
              let peripheral = connection.peripheral else {
            return
        }

        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Verbindet zu mehreren Geräten gleichzeitig
    func connectToMultiple(deviceUUIDs: [String]) {
        for uuid in deviceUUIDs {
            connect(to: uuid)
        }
    }

    /// Liefert alle aktiven Verbindungen
    func getAllActiveConnections() -> [DeviceConnection] {
        connections.values.filter { connection in
            if case .connected = connection.connectionState {
                return true
            }
            return false
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        guard !isScanning, centralManager.state == .poweredOn else {
            return
        }

        centralManager.scanForPeripherals(
            withServices: [UUIDs.flowerCareServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        scanningStateSubject.send(true)
    }

    private func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        scanningStateSubject.send(false)
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn && !devicesToScan.isEmpty {
                startScanning()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let peripheralUUID = peripheral.identifier.uuidString

            // Prüfe ob wir nach diesem Gerät suchen
            guard devicesToScan.contains(peripheralUUID) else { return }

            // Hole Connection und setze Peripheral
            let connection = getConnection(for: peripheralUUID)
            connection.setPeripheral(peripheral)

            // Verbinde
            central.connect(peripheral, options: nil)

            // Entferne aus Scan-Liste
            devicesToScan.remove(peripheralUUID)

            // Stoppe Scan wenn alle gefunden
            if devicesToScan.isEmpty {
                stopScanning()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        Task { @MainActor in
            let connection = connections[peripheral.identifier.uuidString]
            connection?.handleConnected()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let connection = connections[peripheral.identifier.uuidString]
            connection?.handleDisconnected(error: error)
        }
    }
}
```

### Phase 2: ViewModel Integration

```swift
// DeviceDetailsViewModel anpassen
@Observable class DeviceDetailsViewModel {
    let connectionManager = ConnectionPoolManager.shared
    var device: FlowerDeviceDTO
    private var connection: DeviceConnection?
    private var subscription: AnyCancellable?

    init(device: FlowerDeviceDTO) {
        self.device = device

        // Hole Connection für dieses Gerät
        self.connection = connectionManager.getConnection(for: device.uuid)

        // Subscribe zu Sensor-Daten NUR für dieses Gerät
        self.subscription = connection?.sensorDataPublisher.sink { [weak self] data in
            Task { @MainActor in
                await self?.saveSensorData(data)
            }
        }
    }

    func connectToDevice() {
        connectionManager.connect(to: device.uuid)
    }

    func disconnect() {
        connectionManager.disconnect(from: device.uuid)
    }
}
```

### Phase 3: Batch-Updates für Overview

```swift
// OverviewList - alle Geräte gleichzeitig aktualisieren
@Observable class OverviewListViewModel {
    let connectionManager = ConnectionPoolManager.shared
    var allSavedDevices: [FlowerDeviceDTO] = []

    /// Aktualisiert alle Geräte gleichzeitig
    func refreshAllDevices() {
        let deviceUUIDs = allSavedDevices.map { $0.uuid }
        connectionManager.connectToMultiple(deviceUUIDs: deviceUUIDs)

        // Nach kurzer Zeit wieder trennen
        Task {
            try? await Task.sleep(for: .seconds(30))
            for uuid in deviceUUIDs {
                connectionManager.disconnect(from: uuid)
            }
        }
    }
}
```

---

## Technische Überlegungen

### BLE-Limitierungen
- **iOS BLE Limit**: iOS kann ~8-10 gleichzeitige BLE-Verbindungen verwalten
- **Empfehlung**: Maximal 5 gleichzeitige Verbindungen für Stabilität
- **Priorisierung**: Aktive Geräte (DeviceDetails) haben Vorrang

### Connection Pool Strategien

#### Strategie 1: Priority Queue
```
Priorität 1: Aktiv geöffnetes DeviceDetails
Priorität 2: Geräte mit kritischen Werten
Priorität 3: Hintergrund-Updates (rotation)
```

#### Strategie 2: Round-Robin
```
Verbinde zu 3 Geräten → Update → Disconnect
Verbinde zu nächsten 3 Geräten → Update → Disconnect
...
```

### Memory Management
- Auto-Cleanup nach Disconnect
- Weak References in Closures
- Cancellables aufräumen

---

## Implementierungs-Phasen

### Phase 1: Foundation (2-3 Tage)
- [ ] `DeviceConnection` Klasse erstellen
- [ ] `ConnectionPoolManager` Grundgerüst
- [ ] Unit Tests für Connection Logic

### Phase 2: Integration (2-3 Tage)
- [ ] Migration von `FlowerCareManager` zu `ConnectionPoolManager`
- [ ] ViewModel-Anpassungen
- [ ] Publisher-Routing

### Phase 3: Features (1-2 Tage)
- [ ] Batch-Update für Overview
- [ ] Priority Queue
- [ ] Connection Timeout Handling

### Phase 4: Polish (1 Tag)
- [ ] Error Handling
- [ ] Logging/Debugging
- [ ] Performance-Optimierung

**Gesamtaufwand**: ~6-9 Tage

---

## Migration Guide

### Schritt 1: Alte Nutzung
```swift
// Alt
let ble = FlowerCareManager.shared
ble.startScanning(deviceUUID: device.uuid)
ble.sensorDataPublisher.sink { data in ... }
```

### Schritt 2: Neue Nutzung
```swift
// Neu
let poolManager = ConnectionPoolManager.shared
let connection = poolManager.getConnection(for: device.uuid)
poolManager.connect(to: device.uuid)
connection.sensorDataPublisher.sink { data in ... }
```

---

## Alternative Features

### Background Updates (Optional)
```swift
// Nutze BGTaskScheduler für periodische Updates aller Geräte
func scheduleBackgroundRefresh() {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.growguard.refresh",
        using: nil
    ) { task in
        self.refreshAllDevicesInBackground(task: task)
    }
}
```

### Smart Updates (Optional)
- Nur Geräte mit alten Daten aktualisieren
- Nur Geräte mit kritischen Werten priorisieren
- Geräte basierend auf Entfernung (RSSI) gruppieren

---

## Risiken & Mitigation

| Risiko | Wahrscheinlichkeit | Impact | Mitigation |
|--------|-------------------|--------|------------|
| BLE-Verbindungen instabil | Mittel | Hoch | Retry-Logic, Connection Pooling |
| Memory Leaks | Niedrig | Mittel | Weak References, Cleanup |
| Performance-Issues | Mittel | Mittel | Connection Limit, Priorisierung |
| Breaking Changes | Hoch | Hoch | Schrittweise Migration, Feature Flag |

---

## Empfehlung

**✅ Ansatz 1: Connection Pool Manager**

**Begründung:**
1. Entspricht Apple Best Practices
2. Skalierbar für Zukunft
3. Bessere Performance
4. Einfachere Fehlerbehandlung
5. Zentrale Kontrolle über alle Verbindungen

**Nächste Schritte:**
1. Review & Feedback zu diesem Konzept
2. Prototyp von `ConnectionPoolManager` entwickeln
3. Test mit 2 Geräten
4. Schrittweise Migration
