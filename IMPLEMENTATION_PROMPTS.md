# Schritt-für-Schritt Prompts: ConnectionPool Implementation

## ⚠️ Wichtig vor dem Start

**Backup erstellen:**
```bash
git checkout -b feature/connection-pool
git commit -am "Backup before ConnectionPool implementation"
```

**Nach jedem Schritt:**
1. ✅ Code kompilieren lassen
2. ✅ Tests ausführen
3. ✅ App starten und testen
4. ✅ Git Commit erstellen

---

## Phase 1: Foundation - Neue Klassen erstellen

### Prompt 1.1: DeviceConnection Klasse erstellen

```
Erstelle eine neue Swift-Datei GrowGuard/BLE/DeviceConnection.swift mit folgenden Anforderungen:

1. Erstelle eine Klasse DeviceConnection die NSObject und CBPeripheralDelegate erbt
2. Die Klasse soll für GENAU EIN BLE-Gerät verantwortlich sein
3. Implementiere folgende Properties:
   - deviceUUID: String (öffentlich, read-only)
   - peripheral: CBPeripheral? (privat)
   - Connection State Enum mit Zuständen: disconnected, connecting, connected, authenticated, error(Error)
   - Combine Publisher für: SensorData, HistoricalSensorData, ConnectionState
   - Dictionary für BLE Characteristics: [String: CBCharacteristic]
   - Authentication Flag: isAuthenticated
   - SensorDataDecoder instance

4. Implementiere folgende Methoden:
   - init(deviceUUID: String)
   - setPeripheral(_ peripheral: CBPeripheral) - setzt das Peripheral und sich selbst als delegate
   - handleConnected() - wird aufgerufen wenn Peripheral connected
   - handleDisconnected(error: Error?) - wird aufgerufen wenn Peripheral disconnected
   - discoverServices() - startet Service Discovery

5. WICHTIG: Noch KEINE BLE-Logik implementieren, nur die Struktur
6. Nutze die gleichen UUIDs wie in FlowerManager.swift
7. Füge ausführliche Code-Kommentare hinzu

NICHT implementieren:
- Authentication Flow (kommt später)
- Charakteristik Handling (kommt später)
- Data Parsing (kommt später)
```

**Akzeptanzkriterien:**
- [ ] Datei kompiliert ohne Fehler
- [ ] Klasse hat alle Properties
- [ ] Init-Methode funktioniert
- [ ] Keine Compiler-Warnungen

**Test nach diesem Schritt:**
```bash
# App kompilieren
cmd+B

# Git commit
git add GrowGuard/BLE/DeviceConnection.swift
git commit -m "Add DeviceConnection skeleton"
```

---

### Prompt 1.2: ConnectionPoolManager Grundgerüst

```
Erstelle eine neue Swift-Datei GrowGuard/BLE/ConnectionPoolManager.swift mit folgenden Anforderungen:

1. Erstelle eine Klasse ConnectionPoolManager die NSObject und CBCentralManagerDelegate erbt
2. Markiere die Klasse mit @MainActor
3. Implementiere als Singleton mit: static let shared = ConnectionPoolManager()

4. Properties:
   - centralManager: CBCentralManager (privat)
   - connections: [String: DeviceConnection] (privat, Dictionary deviceUUID -> DeviceConnection)
   - devicesToScan: Set<String> (privat, UUIDs die gesucht werden)
   - isScanning: Bool (privat)
   - scanningStateSubject: CurrentValueSubject<Bool, Never> (privat)

5. Init-Methode:
   - private override init()
   - Initialisiere centralManager mit self als delegate

6. Public API Methoden (nur Signaturen, leere Implementierung):
   - func getConnection(for deviceUUID: String) -> DeviceConnection
   - func connect(to deviceUUID: String)
   - func disconnect(from deviceUUID: String)
   - func connectToMultiple(deviceUUIDs: [String])
   - func getAllActiveConnections() -> [DeviceConnection]

7. Private Methoden (nur Signaturen):
   - func startScanning()
   - func stopScanning()

8. CBCentralManagerDelegate Stubs:
   - centralManagerDidUpdateState(_:)
   - centralManager(_:didDiscover:advertisementData:rssi:)
   - centralManager(_:didConnect:)
   - centralManager(_:didDisconnectPeripheral:error:)

9. WICHTIG: Alle Delegate-Methoden müssen nonisolated sein mit Task { @MainActor in ... }

10. Nutze die gleichen Service UUIDs wie FlowerManager

NOCH KEINE Implementierung der Logik, nur die Struktur!
```

**Akzeptanzkriterien:**
- [ ] Datei kompiliert ohne Fehler
- [ ] Singleton funktioniert
- [ ] Alle Methoden-Signaturen vorhanden
- [ ] Keine Compiler-Warnungen

**Test nach diesem Schritt:**
```bash
# App kompilieren
cmd+B

# Git commit
git add GrowGuard/BLE/ConnectionPoolManager.swift
git commit -m "Add ConnectionPoolManager skeleton"
```

---

## Phase 2: Core-Logik implementieren

### Prompt 2.1: ConnectionPoolManager - Connect/Disconnect Logic

```
Implementiere die Connect/Disconnect-Logik im ConnectionPoolManager:

1. Implementiere getConnection(for:):
   - Prüfe ob Connection bereits existiert in connections Dictionary
   - Falls ja: returniere existierende
   - Falls nein: erstelle neue DeviceConnection, speichere in Dictionary, returniere sie

2. Implementiere connect(to:):
   - Hole DeviceConnection via getConnection(for:)
   - Prüfe Connection State - falls bereits connected, return früh
   - Erstelle UUID aus deviceUUID String
   - Nutze centralManager.retrievePeripherals(withIdentifiers:) um bekannte Peripherals zu finden
   - Falls Peripheral gefunden:
     * Setze Peripheral auf Connection via setPeripheral()
     * Rufe centralManager.connect(peripheral, options: nil) auf
   - Falls NICHT gefunden:
     * Füge deviceUUID zu devicesToScan hinzu
     * Rufe startScanning() auf

3. Implementiere disconnect(from:):
   - Hole Connection aus Dictionary
   - Prüfe ob Peripheral existiert
   - Rufe centralManager.cancelPeripheralConnection(peripheral) auf

4. Implementiere connectToMultiple(deviceUUIDs:):
   - Iteriere über alle UUIDs
   - Rufe connect(to:) für jede UUID auf

5. Implementiere getAllActiveConnections():
   - Filtere connections.values
   - Returniere nur Connections mit State == .connected oder .authenticated

6. Füge Logging mit AppLogger.ble hinzu für alle Aktionen

Beachte:
- Nutze die gleiche Logik wie in FlowerManager.swift:149-171
- Error Handling: guard statements verwenden
- Alle Operationen müssen @MainActor sein
```

**Akzeptanzkriterien:**
- [ ] Code kompiliert
- [ ] connect() erstellt oder holt Connection
- [ ] disconnect() bricht Verbindung ab
- [ ] Logging funktioniert

**Test nach diesem Schritt:**
```bash
cmd+B
git add GrowGuard/BLE/ConnectionPoolManager.swift
git commit -m "Implement connect/disconnect logic"
```

---

### Prompt 2.2: ConnectionPoolManager - Scanning Logic

```
Implementiere die Scanning-Logik im ConnectionPoolManager:

1. Implementiere startScanning():
   - Guard: prüfe !isScanning
   - Guard: prüfe centralManager.state == .poweredOn
   - Rufe centralManager.scanForPeripherals() auf
   - Service Filter: [UUIDs.flowerCareServiceUUID] (importiere von UUIDs.swift)
   - Options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
   - Setze isScanning = true
   - Update scanningStateSubject.send(true)
   - Füge Logging hinzu

2. Implementiere stopScanning():
   - Guard: prüfe isScanning
   - Rufe centralManager.stopScan() auf
   - Setze isScanning = false
   - Update scanningStateSubject.send(false)
   - Füge Logging hinzu

3. Implementiere centralManagerDidUpdateState:
   - Prüfe wenn state == .poweredOn
   - Falls devicesToScan nicht leer: rufe startScanning() auf
   - Füge Logging für alle States hinzu

4. Implementiere centralManager(_:didDiscover:advertisementData:rssi:):
   - Hole peripheralUUID via peripheral.identifier.uuidString
   - Prüfe ob peripheralUUID in devicesToScan enthalten ist
   - Falls JA:
     * Hole Connection via getConnection(for: peripheralUUID)
     * Setze Peripheral auf Connection
     * Verbinde via centralManager.connect()
     * Entferne aus devicesToScan
     * Falls devicesToScan leer: stopScanning()
   - Füge Logging hinzu

Beachte:
- Orientiere dich an FlowerManager.swift Zeilen 204-236
- Delegate-Methoden: nonisolated + Task { @MainActor in }
```

**Akzeptanzkriterien:**
- [ ] Scanning startet/stoppt korrekt
- [ ] didDiscover findet Geräte
- [ ] Auto-Connect nach Discovery
- [ ] Logging zeigt alle Events

**Test nach diesem Schritt:**
```bash
cmd+B
git add GrowGuard/BLE/ConnectionPoolManager.swift
git commit -m "Implement scanning logic"
```

---

### Prompt 2.3: ConnectionPoolManager - Connection Callbacks

```
Implementiere die Connection-Callback-Methoden im ConnectionPoolManager:

1. Implementiere centralManager(_:didConnect:):
   - Hole peripheralUUID via peripheral.identifier.uuidString
   - Hole Connection aus connections Dictionary
   - Falls Connection existiert: rufe connection.handleConnected() auf
   - Füge Logging hinzu: "Connected to device: \(peripheralUUID)"

2. Implementiere centralManager(_:didDisconnectPeripheral:error:):
   - Hole peripheralUUID via peripheral.identifier.uuidString
   - Hole Connection aus connections Dictionary
   - Falls Connection existiert: rufe connection.handleDisconnected(error: error) auf
   - Falls error != nil: logge Error
   - Füge Logging hinzu: "Disconnected from device: \(peripheralUUID)"

Beachte:
- Beide Methoden müssen nonisolated sein
- Nutze Task { @MainActor in } für den Body
- Error Handling: optionale error Parameter prüfen
```

**Akzeptanzkriterien:**
- [ ] didConnect ruft handleConnected() auf
- [ ] didDisconnect ruft handleDisconnected() auf
- [ ] Errors werden geloggt

**Test nach diesem Schritt:**
```bash
cmd+B
git add GrowGuard/BLE/ConnectionPoolManager.swift
git commit -m "Implement connection callbacks"
```

---

### Prompt 2.4: DeviceConnection - Connection Handling

```
Implementiere die Connection-Handling-Methoden in DeviceConnection:

1. Implementiere handleConnected():
   - Update stateSubject.send(.connected)
   - Rufe peripheral?.discoverServices([UUIDs.flowerCareServiceUUID]) auf
   - Füge Logging hinzu: "Device \(deviceUUID) connected, discovering services"

2. Implementiere handleDisconnected(error:):
   - Falls error != nil:
     * Update stateSubject.send(.error(error!))
     * Logge Error
   - Falls error == nil:
     * Update stateSubject.send(.disconnected)
   - Reset isAuthenticated = false
   - Logge: "Device \(deviceUUID) disconnected"

3. Implementiere peripheral(_:didDiscoverServices:):
   - Guard für error
   - Iteriere über peripheral.services
   - Für jeden Service: rufe peripheral.discoverCharacteristics(nil, for: service) auf
   - Logge gefundene Services

4. Implementiere peripheral(_:didDiscoverCharacteristicsFor:error:):
   - Guard für error
   - Iteriere über service.characteristics
   - Speichere Characteristics im Dictionary: characteristics[characteristic.uuid.uuidString] = characteristic
   - Logge gefundene Characteristics
   - Falls alle wichtigen Characteristics gefunden: starte Authentication

Orientiere dich an:
- FlowerManager.swift Zeilen 351-454 für Service/Characteristic Discovery
- Nutze die gleichen UUIDs

NOCH KEINE Authentication implementieren, kommt im nächsten Schritt!
```

**Akzeptanzkriterien:**
- [ ] Connection State Updates funktionieren
- [ ] Service Discovery funktioniert
- [ ] Characteristics werden gespeichert

**Test nach diesem Schritt:**
```bash
cmd+B
git add GrowGuard/BLE/DeviceConnection.swift
git commit -m "Implement connection handling in DeviceConnection"
```

---

## Phase 3: BLE-Protokoll implementieren

### Prompt 3.1: DeviceConnection - Authentication

```
Implementiere die Authentication-Logik in DeviceConnection:

1. Füge Properties hinzu:
   - authenticationStep: Int (privat)
   - expectedResponse: Data? (privat)

2. Erstelle Methode startAuthentication():
   - Kopiere die komplette Authentication-Logik aus FlowerManager.swift Zeilen 480-545
   - Passe an für diese Klasse (self statt FlowerCareManager)
   - Nutze characteristics Dictionary statt direkten Properties
   - Bei erfolgreichem Auth: setze isAuthenticated = true und stateSubject.send(.authenticated)

3. Erstelle Methode handleAuthenticationResponse(_ data: Data):
   - Kopiere Logik aus FlowerManager.swift Zeilen 510-545
   - Passe an für diese Klasse

4. Implementiere peripheral(_:didUpdateValueFor:error:):
   - Prüfe ob Authentication läuft: !isAuthenticated
   - Falls JA: rufe handleAuthenticationResponse auf
   - Falls NEIN: später für Sensor-Daten (kommt in nächstem Schritt)

Beachte:
- Nutze die EXAKT gleiche Authentication wie FlowerManager
- Teste mit einem echten Gerät
- Füge ausführliches Logging hinzu
```

**Akzeptanzkriterien:**
- [ ] Authentication startet nach Characteristic Discovery
- [ ] Authentication-Steps funktionieren
- [ ] State wechselt zu .authenticated

**Test nach diesem Schritt:**
```bash
cmd+B

# WICHTIG: Mit echtem Gerät testen!
# 1. App starten
# 2. Ein Gerät verbinden
# 3. Logs prüfen: Authentication erfolgreich?

git add GrowGuard/BLE/DeviceConnection.swift
git commit -m "Implement authentication in DeviceConnection"
```

---

### Prompt 3.2: DeviceConnection - Live Sensor Data

```
Implementiere Live-Sensor-Daten in DeviceConnection:

1. Erstelle Methode requestLiveData():
   - Kopiere Logik aus FlowerManager.swift für Real-Time Sensor Data Request
   - Schreibe an die richtige Characteristic
   - Füge Logging hinzu

2. Erweitere peripheral(_:didUpdateValueFor:error:):
   - Falls isAuthenticated == true:
     * Prüfe welche Characteristic updated wurde
     * Falls Real-Time Sensor Characteristic:
       - Dekodiere mit decoder.decodeSensorData(data)
       - Bei Erfolg: sende via sensorDataSubject.send(sensorData)
     * Falls Firmware/Battery Characteristic:
       - Dekodiere entsprechend
       - Update Device Info

3. Erstelle Methode stopLiveData():
   - Stoppe Live-Daten-Updates falls nötig

Orientiere dich an:
- FlowerManager.swift Zeilen 560-660 für Live Data Request
- FlowerManager.swift Zeilen 732-800 für Data Parsing
- SensorDataDecoder für Dekodierung
```

**Akzeptanzkriterien:**
- [ ] Live-Daten können angefragt werden
- [ ] Sensor-Daten werden dekodiert
- [ ] Publisher sendet Daten

**Test nach diesem Schritt:**
```bash
cmd+B

# Mit echtem Gerät testen:
# 1. Verbinden
# 2. Live-Daten anfordern
# 3. Prüfen ob Daten ankommen

git add GrowGuard/BLE/DeviceConnection.swift
git commit -m "Implement live sensor data in DeviceConnection"
```

---

### Prompt 3.3: DeviceConnection - Historical Data (Optional)

```
Implementiere Historical-Daten in DeviceConnection:

1. Erstelle Properties:
   - totalEntries: Int
   - currentEntryIndex: Int
   - isHistoryFlowActive: Bool

2. Erstelle Methode startHistoryDataFlow():
   - Kopiere Logik aus FlowerManager.swift Zeilen 548-665
   - Passe an für diese Klasse

3. Erstelle Methode handleHistoryData(_ data: Data):
   - Dekodiere Historical Data
   - Sende via historicalDataSubject.send()

4. Erweitere peripheral(_:didUpdateValueFor:error:):
   - Prüfe auf History-Characteristics
   - Verarbeite Entry Count, Device Time, History Data

Orientiere dich an:
- FlowerManager.swift Zeilen 666-902 für History Flow
- HistoricalSensorData Model

HINWEIS: Dieser Schritt kann übersprungen werden wenn nur Live-Daten benötigt werden!
```

**Akzeptanzkriterien (falls implementiert):**
- [ ] History Data Flow funktioniert
- [ ] Entry Count wird korrekt gelesen
- [ ] Historical Data wird dekodiert

**Test nach diesem Schritt:**
```bash
cmd+B
git add GrowGuard/BLE/DeviceConnection.swift
git commit -m "Implement historical data in DeviceConnection"
```

---

## Phase 4: Integration in ViewModels

### Prompt 4.1: DeviceDetailsViewModel Migration

```
Migriere DeviceDetailsViewModel zu ConnectionPoolManager:

WICHTIG: Mache KEINEN Breaking Change! Die alte Implementierung muss parallel funktionieren!

1. Füge neue Property hinzu:
   - private let connectionPool = ConnectionPoolManager.shared
   - private var deviceConnection: DeviceConnection?

2. Erstelle neue Methode connectViaPool():
   - Hole Connection: deviceConnection = connectionPool.getConnection(for: device.uuid)
   - Subscribe zu deviceConnection.sensorDataPublisher
   - Subscribe zu deviceConnection.connectionStatePublisher
   - Verbinde: connectionPool.connect(to: device.uuid)

3. VORERST: Behalte alte Methode (ble.connectToKnownDevice) als Fallback

4. Füge Feature-Flag hinzu:
   - private let useConnectionPool = true // später via UserDefaults oder Build Config
   - In init: prüfe Flag und nutze entweder connectViaPool() oder alte Methode

5. Teste BEIDE Wege:
   - useConnectionPool = true → neue Implementierung
   - useConnectionPool = false → alte Implementierung

NICHT ändern:
- Bestehende Properties
- Public Interface
- UI Code
```

**Akzeptanzkriterien:**
- [ ] App kompiliert
- [ ] Mit useConnectionPool = false: App funktioniert wie vorher
- [ ] Mit useConnectionPool = true: App funktioniert mit neuem Pool
- [ ] Keine UI-Brüche

**Test nach diesem Schritt:**
```bash
cmd+B

# Test 1: Alte Implementierung
# - Setze useConnectionPool = false
# - App starten, Gerät verbinden
# - Prüfen ob alles funktioniert

# Test 2: Neue Implementierung
# - Setze useConnectionPool = true
# - App starten, Gerät verbinden
# - Prüfen ob alles funktioniert

git add GrowGuard/DeviceDetails/DeviceDetailsViewModel.swift
git commit -m "Add ConnectionPool support to DeviceDetailsViewModel (with fallback)"
```

---

### Prompt 4.2: Parallele Verbindungen testen

```
Implementiere Test-Funktionalität für mehrere gleichzeitige Verbindungen:

1. Erstelle neue View: GrowGuard/Utils/ConnectionPoolDebugView.swift
   - Liste alle aktiven Connections
   - Zeige Connection State pro Gerät
   - Button: "Connect All Devices"
   - Button: "Disconnect All"

2. Implementiere in OverviewListViewModel:
   - Methode: func connectAllDevicesForRefresh()
   - Nutze connectionPool.connectToMultiple(deviceUUIDs: ...)
   - Timer: nach 30 Sekunden automatisch disconnect

3. Füge Debug-View zu AppSettings hinzu (nur in Debug-Builds):
   #if DEBUG
   NavigationLink("Connection Pool Debug", destination: ConnectionPoolDebugView())
   #endif

4. Teste mit MEHREREN echten Geräten:
   - Mindestens 2 Geräte
   - Verbinde beide gleichzeitig
   - Prüfe ob beide Daten senden
   - Prüfe ob keine Daten vertauscht werden

WICHTIG: Dies ist nur für Testing, nicht für Production!
```

**Akzeptanzkriterien:**
- [ ] Debug View zeigt alle Connections
- [ ] "Connect All" verbindet mehrere Geräte
- [ ] Jedes Gerät sendet isolierte Daten
- [ ] Keine Daten-Vermischung

**Test nach diesem Schritt:**
```bash
cmd+B

# Test mit 2+ Geräten:
# 1. Gehe zu Settings → Connection Pool Debug
# 2. Klicke "Connect All Devices"
# 3. Beobachte Logs
# 4. Prüfe ob jedes Gerät seinen eigenen Stream hat

git add .
git commit -m "Add ConnectionPool debug view for testing"
```

---

## Phase 5: Cleanup & Production Ready

### Prompt 5.1: Feature-Flag entfernen

```
Entferne die alte FlowerManager-Implementierung vollständig:

1. In DeviceDetailsViewModel:
   - Entferne useConnectionPool Flag
   - Entferne alte BLE-Subscription
   - Nutze NUR noch ConnectionPool
   - Entferne Property: let ble = FlowerCareManager.shared

2. In allen anderen ViewModels:
   - Suche nach FlowerCareManager.shared
   - Ersetze durch ConnectionPoolManager.shared

3. Teste ALLE Flows:
   - Gerät hinzufügen
   - Gerät öffnen
   - Live-Daten laden
   - Historical Data laden (falls implementiert)
   - Gerät löschen

4. NOCH NICHT löschen: FlowerManager.swift (als Backup behalten vorerst)

Prüfe:
- Keine Compile Errors
- Keine Memory Leaks (Instruments)
- Kein Crash beim Connect/Disconnect
```

**Akzeptanzkriterien:**
- [ ] Alle ViewModels nutzen ConnectionPool
- [ ] Keine Referenzen zu FlowerCareManager.shared mehr
- [ ] App funktioniert vollständig
- [ ] Keine Crashes

**Test nach diesem Schritt:**
```bash
cmd+B

# Vollständiger Regression Test:
# 1. Neues Gerät hinzufügen
# 2. Gerät öffnen und verbinden
# 3. Live-Daten prüfen
# 4. Disconnect
# 5. Zweites Gerät hinzufügen
# 6. BEIDE gleichzeitig verbinden
# 7. Prüfen ob beide funktionieren

git add .
git commit -m "Remove old FlowerManager implementation"
```

---

### Prompt 5.2: Error Handling & Retry Logic

```
Verbessere Error Handling im ConnectionPoolManager:

1. Füge Properties hinzu:
   - connectionRetries: [String: Int] (Device UUID → Retry Count)
   - maxRetries: Int = 3

2. Erweitere disconnect(from:) Error Handling:
   - Bei unerwarteter Disconnection: automatisch retry
   - Inkrementiere Retry Counter
   - Nach maxRetries: gebe auf und informiere User

3. Erstelle Methode handleConnectionError:
   - Logge Error
   - Entscheide ob Retry sinnvoll
   - Implementiere Exponential Backoff

4. Füge Timeout hinzu:
   - Connection Timeout: 30 Sekunden
   - Falls keine Response: cancel und retry

5. Erweitere DeviceConnection um Error Recovery:
   - Bei Auth-Fehler: neu verbinden
   - Bei Characteristic-Fehler: Service Discovery wiederholen

Orientiere dich an FlowerManager.swift Zeilen 971-1033 für Error Handling
```

**Akzeptanzkriterien:**
- [ ] Connection Errors werden gehandelt
- [ ] Auto-Retry bei Disconnects
- [ ] Timeout funktioniert
- [ ] User wird informiert bei permanenten Fehlern

**Test nach diesem Schritt:**
```bash
cmd+B

# Error Tests:
# 1. Verbinde zu Gerät
# 2. Schalte Bluetooth am Gerät aus
# 3. Prüfe ob Retry funktioniert
# 4. Prüfe ob nach 3 Retries aufgegeben wird

git add .
git commit -m "Add error handling and retry logic"
```

---

### Prompt 5.3: Memory Management & Cleanup

```
Implementiere Memory Management und Cleanup:

1. In DeviceConnection:
   - Füge deinit hinzu mit Cleanup-Logik
   - Cancelle alle Timer
   - Setze peripheral.delegate = nil
   - Logge Deallocation

2. In ConnectionPoolManager:
   - Implementiere removeConnection(for:) Methode
   - Räume auf nach disconnect wenn Connection nicht mehr benötigt
   - Implementiere cleanupStaleConnections() für alte Connections

3. In DeviceDetailsViewModel:
   - Füge deinit hinzu
   - Cancelle alle Subscriptions
   - Disconnect beim View-Close (onDisappear)

4. Prüfe auf Retain Cycles:
   - Nutze [weak self] in allen Closures
   - Prüfe alle Delegate-References

5. Teste mit Instruments:
   - Öffne "Leaks" Instrument
   - Verbinde/Disconnect mehrfach
   - Prüfe auf Memory Leaks
```

**Akzeptanzkriterien:**
- [ ] Keine Memory Leaks (Instruments)
- [ ] deinit wird aufgerufen
- [ ] Connections werden aufgeräumt
- [ ] Keine Zombie-Objects

**Test nach diesem Schritt:**
```bash
cmd+B

# Instruments Test:
# 1. Öffne Instruments (Product → Profile)
# 2. Wähle "Leaks"
# 3. 10x Gerät verbinden und disconnect
# 4. Prüfe auf Leaks

git add .
git commit -m "Add memory management and cleanup"
```

---

### Prompt 5.4: Performance Optimierung

```
Optimiere Performance für mehrere gleichzeitige Verbindungen:

1. Implementiere Connection Pooling:
   - Maximal 5 gleichzeitige Verbindungen
   - Queue für wartende Verbindungen
   - Priority Queue: aktive Views haben Vorrang

2. Erstelle ConnectionPriorityManager:
   - Priorität 1: Aktuell sichtbare DeviceDetails
   - Priorität 2: Background Refresh
   - Automatisch disconnect bei niedrigerer Priorität

3. Implementiere Batch-Updates:
   - Gruppiere Updates alle 5 Sekunden
   - Verhindere zu häufige UI-Updates

4. RSSI-based Connection Quality:
   - Prüfe Signalstärke
   - Warne bei schlechter Verbindung
   - Auto-disconnect bei zu schwachem Signal

5. Background Task Support (Optional):
   - Nutze BGTaskScheduler
   - Periodic Background Refresh

Beachte:
- Performance wichtiger als Features
- 5 Connections = sichere Grenze für iOS
- UI muss flüssig bleiben
```

**Akzeptanzkriterien:**
- [ ] Max 5 Connections gleichzeitig
- [ ] Priority System funktioniert
- [ ] UI bleibt flüssig
- [ ] Keine Performance-Issues

**Test nach diesem Schritt:**
```bash
cmd+B

# Performance Test:
# 1. Verbinde zu 5 Geräten
# 2. Öffne/Schließe DeviceDetails mehrfach
# 3. Prüfe UI-Performance (sollte flüssig sein)
# 4. Prüfe CPU-Usage (sollte < 20% sein)

git add .
git commit -m "Add performance optimizations"
```

---

## Phase 6: Finalisierung

### Prompt 6.1: Unit Tests

```
Erstelle Unit Tests für ConnectionPoolManager:

1. Erstelle GrowGuardTests/BLE/ConnectionPoolManagerTests.swift

2. Teste folgende Szenarien:
   - getConnection erstellt neue Connection beim ersten Aufruf
   - getConnection returned existierende Connection beim zweiten Aufruf
   - connect fügt deviceUUID zu devicesToScan hinzu wenn Peripheral unbekannt
   - disconnect entfernt Connection
   - connectToMultiple verbindet zu allen Geräten
   - getAllActiveConnections returned nur connected Connections

3. Nutze Mock Objects:
   - MockCBCentralManager
   - MockCBPeripheral
   - MockDeviceConnection

4. Teste Edge Cases:
   - Verbinden wenn Bluetooth aus
   - Disconnect während Connection
   - Gleichzeitige Connects

Orientiere dich an GrowGuardTests/BLE/FlowerManagerHistoryTests.swift
```

**Akzeptanzkriterien:**
- [ ] Tests kompilieren
- [ ] Alle Tests grün
- [ ] Code Coverage > 80%

**Test nach diesem Schritt:**
```bash
# Tests ausführen
cmd+U

git add GrowGuardTests/BLE/ConnectionPoolManagerTests.swift
git commit -m "Add unit tests for ConnectionPoolManager"
```

---

### Prompt 6.2: Dokumentation

```
Erstelle Dokumentation für die neue Architektur:

1. Erstelle GrowGuard/BLE/README.md:
   - Übersicht über ConnectionPool-Architektur
   - Wie man verbindet: Code-Beispiele
   - Wie man disconnected
   - Batch-Updates Beispiel
   - Troubleshooting

2. Füge Code-Kommentare hinzu:
   - Alle public Methoden dokumentieren
   - Komplexe Algorithmen erklären
   - TODOs für Future Improvements

3. Erstelle Architecture Decision Record (ADR):
   - Datei: docs/ADR-001-ConnectionPool.md
   - Warum ConnectionPool?
   - Alternativen
   - Entscheidung
   - Konsequenzen

4. Update existing README:
   - Erkläre neue Architektur
   - Migration Guide für Entwickler
```

**Akzeptanzkriterien:**
- [ ] README.md existiert
- [ ] Code-Beispiele funktionieren
- [ ] ADR ist vollständig

**Test nach diesem Schritt:**
```bash
git add .
git commit -m "Add documentation for ConnectionPool"
```

---

### Prompt 6.3: Final Cleanup

```
Finales Cleanup vor Production:

1. Entferne Debug Code:
   - Entferne ConnectionPoolDebugView (oder hinter Feature Flag)
   - Entferne übermäßiges Logging
   - Entferne print() Statements

2. Entferne alte Implementierung:
   - JETZT ERST: Lösche FlowerManager.swift (oder archiviere in docs/)
   - Entferne ungenutzte Properties
   - Führe "find unused code" Script aus

3. Code Review Checklist:
   - [ ] Keine Force Unwraps (!)
   - [ ] Alle Errors werden gehandelt
   - [ ] Alle Subscriptions haben [weak self]
   - [ ] Keine TODOs im Production Code
   - [ ] Logging ist angemessen

4. Update Build Number und Release Notes

5. Erstelle Pull Request:
   - Titel: "Feature: Multi-Device BLE Connection Pool"
   - Description: Detaillierte Änderungen
   - Screenshots/Videos von Tests
```

**Akzeptanzkriterien:**
- [ ] Kein Debug-Code in Production
- [ ] Alte Implementierung entfernt
- [ ] Code Review bestanden
- [ ] Ready for merge

**Test nach diesem Schritt:**
```bash
# Final Regression Test
# 1. Clean Build
cmd+shift+K
cmd+B

# 2. Alle Tests
cmd+U

# 3. Manuelle Tests
# - Neues Gerät hinzufügen
# - 3 Geräte gleichzeitig verbinden
# - Alle Features testen

# Git
git add .
git commit -m "Final cleanup and production ready"
git push origin feature/connection-pool

# Pull Request erstellen
```

---

## Zusammenfassung der Phasen

| Phase | Prompts | Dauer (geschätzt) | Risiko |
|-------|---------|-------------------|---------|
| Phase 1 | 1.1 - 1.2 | 1 Tag | Niedrig |
| Phase 2 | 2.1 - 2.4 | 2 Tage | Mittel |
| Phase 3 | 3.1 - 3.3 | 2 Tage | Hoch |
| Phase 4 | 4.1 - 4.2 | 1 Tag | Mittel |
| Phase 5 | 5.1 - 5.4 | 2 Tage | Mittel |
| Phase 6 | 6.1 - 6.3 | 1 Tag | Niedrig |
| **Total** | **18 Prompts** | **9 Tage** | - |

---

## Wichtige Hinweise

### Zwischen jedem Prompt:
1. ✅ **Kompilieren**: cmd+B
2. ✅ **Tests**: cmd+U (falls vorhanden)
3. ✅ **App starten**: Manuell testen
4. ✅ **Git Commit**: Inkrementelle Commits

### Bei Problemen:
1. **Nicht weitermachen** wenn Tests fehlschlagen
2. **Logs prüfen** bei Fehlern
3. **Git revert** zum letzten funktionierenden Stand
4. **Issue dokumentieren** bevor du weitermachst

### Rollback-Plan:
```bash
# Falls etwas schief geht:
git checkout main
git branch -D feature/connection-pool

# Neustart:
git checkout -b feature/connection-pool
# Von vorne beginnen
```

### Testing-Strategie:
- **Nach Phase 1-2**: Nur Compilation Tests
- **Nach Phase 3**: Tests mit 1 echtem Gerät
- **Nach Phase 4**: Tests mit 2+ echten Geräten
- **Nach Phase 5**: Full Regression Test
- **Nach Phase 6**: Production-Ready Test

---

## Nächste Schritte

Beginne mit **Prompt 1.1** und arbeite dich schrittweise durch!

**Viel Erfolg! 🚀**
