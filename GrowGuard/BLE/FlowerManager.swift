//
//  FlowerManager.swift
//  GrowGuard
//
//  Created by Veit Progl on 02.06.24.
//

import Foundation
import CoreBluetooth
import Combine

class FlowerCareManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripheral: CBPeripheral?
    var modeChangeCharacteristic: CBCharacteristic? // Neue Charakteristik für Mode Change (Handle 0x33)
    var realTimeSensorValuesCharacteristic: CBCharacteristic?
    var historyControlCharacteristic: CBCharacteristic?
    var historyDataCharacteristic: CBCharacteristic?
    var deviceTimeCharacteristic: CBCharacteristic?
    var entryCountCharacteristic: CBCharacteristic?
    var ledControlCharacteristic: CBCharacteristic?
    var isConnected = false
    
    private var isScanning = false
    private var deviceUUID: String?
    private let repositoryManager = RepositoryManager.shared
    private var totalEntries: Int = 0
    private var currentEntryIndex: Int = 0
    private var invalidDataRetryCount = 0
    private let maxRetryAttempts = 3
    
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()

    private let decoder = SensorDataDecoder()

    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        return sensorDataSubject.eraseToAnyPublisher()
    }
    
    var historicalDataPublisher: AnyPublisher<HistoricalSensorData, Never> {
        return historicalDataSubject.eraseToAnyPublisher()
    }
    
    static var shared = FlowerCareManager()

    // MARK: - Safe Timer Management
    
    /// CRITICAL FIX: Safe timer scheduling to prevent timer cascades
    private func safeScheduleTimer(delay: TimeInterval, action: @escaping () -> Void) {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] timer in
            action()
            self?.removeTimer(timer)
        }
        
        activeTimers.insert(timer)
    }
    
    private func removeTimer(_ timer: Timer) {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        activeTimers.remove(timer)
        timer.invalidate()
    }
    
    private func cancelAllTimers() {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        activeTimers.forEach { $0.invalidate() }
        activeTimers.removeAll()
    }

    // Neues Flag zur Vermeidung doppelter Anfragen
    private var isRequestingData = false
    private var requestTimeoutTimer: Timer?
    private var activeTimers: Set<Timer> = []
    private let timerLock = NSLock()
    private let requestTimeout = 10.0  // Timeout in Sekunden

    private var deviceBootTime: Date?

    // Add these properties to your FlowerCareManager class
    private let loadingProgressSubject = CurrentValueSubject<(current: Int, total: Int), Never>((0, 0))
    private let loadingStateSubject = CurrentValueSubject<LoadingState, Never>(.idle)

    // Create an enum for loading states
    enum LoadingState: Equatable {
        case idle
        case loading
        case completed
        case error(String)
    }

    // Add these near your other enum definitions

    // Connection quality enum
    enum ConnectionQuality {
        case unknown
        case poor
        case fair
        case good
        
        var description: String {
            switch self {
            case .unknown: return "Unknown"
            case .poor: return "Poor"
            case .fair: return "Fair"
            case .good: return "Good"
            }
        }
    }

    // Public publishers
    var loadingProgressPublisher: AnyPublisher<(current: Int, total: Int), Never> {
        return loadingProgressSubject.eraseToAnyPublisher()
    }

    var loadingStatePublisher: AnyPublisher<LoadingState, Never> {
        return loadingStateSubject.eraseToAnyPublisher()
    }

    // Add these properties to your class
    private var liveDataRequested = false
    private var historicalDataRequested = false

    // Add these properties to your class
    private let connectionQualitySubject = CurrentValueSubject<ConnectionQuality, Never>(.unknown)

    // Public publisher
    var connectionQualityPublisher: AnyPublisher<ConnectionQuality, Never> {
        return connectionQualitySubject.eraseToAnyPublisher()
    }

    override init() {
        super.init()
        
        // Use background queue for BLE in debug builds to reduce main thread blocking
        #if DEBUG
        let bleQueue = DispatchQueue(label: "com.growguard.ble", qos: .userInitiated)
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        #else
        centralManager = CBCentralManager(delegate: self, queue: nil)
        #endif
    }

    func startScanning(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        guard let centralManager = centralManager else { return }
        
        // CRITICAL FIX: Cancel existing timers before starting new operations
        cancelAllTimers()
        
        if (!isScanning && centralManager.state == .poweredOn) {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            isScanning = true
            print("Scanning started")
        }
    }

    func stopScanning() {
        guard let centralManager = centralManager else { return }
        
        // CRITICAL FIX: Cancel all timers when stopping operations
        cancelAllTimers()
        
        if (isScanning) {
            centralManager.stopScan()
            isScanning = false
            print("Scanning stopped")
        }
    }
    
    func connectToKnownDevice(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        guard let uuid = UUID(uuidString: deviceUUID) else {
            print("Invalid device UUID: \(deviceUUID)")
            return
        }
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            discoveredPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
            print("Connecting to known device...")
        } else {
            print("Known device not found, starting scan...")
            startScanning(deviceUUID: deviceUUID)
        }
    }
    
    func disconnect() {
        guard let centralManager = centralManager, let peripheral = discoveredPeripheral else { return }

        centralManager.cancelPeripheralConnection(peripheral)
        print("Disconnecting from peripheral...")

        // Reset properties
        discoveredPeripheral = nil
        realTimeSensorValuesCharacteristic = nil
        historyControlCharacteristic = nil
        historyDataCharacteristic = nil
        deviceTimeCharacteristic = nil
        entryCountCharacteristic = nil

        isScanning = false
        deviceUUID = nil
        totalEntries = 0
        currentEntryIndex = 0
        isConnected = false
        
        // Reset request flags
        liveDataRequested = false
        historicalDataRequested = false
    }
    
    func reloadScanning() {
        guard let centralManager = centralManager else { return }
        if (centralManager.state == .poweredOn) {
            if (isScanning) {
                centralManager.stopScan()
                print("Scanning stopped for reload")
            }
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            isScanning = true
            print("Scanning restarted")
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == .poweredOff) {
            print("Bluetooth is not available.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if (peripheral.identifier.uuidString == deviceUUID) {
            centralManager.stopScan()
            discoveredPeripheral = peripheral
            discoveredPeripheral?.delegate = self
            centralManager.connect(discoveredPeripheral!, options: nil)
            print("Flower Care Sensor found. Connecting...")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to: \(peripheral.name ?? "Unknown")")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        
        // Wichtig: Vielleicht muss zuerst eine Authentifizierung erfolgen
        // Manche Geräte benötigen einen speziellen Handshake
    }

    // Add this delegate method to detect disconnections
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from peripheral: \(peripheral.identifier)")
        
        // Reset connection state
        isConnected = false
        
        // Pause any ongoing operations
        let wasRequestingData = isRequestingData
        isRequestingData = false
        
        // If we were in the middle of history data retrieval
        if totalEntries > 0 && currentEntryIndex < totalEntries {
            print("Disconnected during history retrieval. Reconnecting...")
            // Try to reconnect
            centralManager.connect(peripheral, options: nil)
        } else if wasRequestingData {
            print("Disconnected during sensor data request")
            // Try to reconnect if needed
            centralManager.connect(peripheral, options: nil)
        }
    }

    // MARK: - CBPeripheralDelegate Methods
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let deviceName = peripheral.name {
            print("Discovered device: \(deviceName), UUID: \(peripheral.identifier)")
        }
        
        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                switch characteristic.uuid {
                case deviceModeChangeCharacteristicUUID:
                    modeChangeCharacteristic = characteristic
                    ledControlCharacteristic = characteristic
                case realTimeSensorValuesCharacteristicUUID:
                    realTimeSensorValuesCharacteristic = characteristic
                case firmwareVersionCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                case deviceNameCharacteristicUUID:
                    peripheral.readValue(for: characteristic)
                case historyControlCharacteristicUUID:
                    historyControlCharacteristic = characteristic
                case historicalSensorValuesCharacteristicUUID:
                    historyDataCharacteristic = characteristic
                case deviceTimeCharacteristicUUID:
                    deviceTimeCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                case entryCountCharacteristicUUID:
                    entryCountCharacteristic = characteristic
                default:
                    break
                }
            }
        }

        // Now only start operations if they were explicitly requested
        if liveDataRequested && modeChangeCharacteristic != nil && realTimeSensorValuesCharacteristic != nil {
            requestFreshSensorData()
        }
        
        if historicalDataRequested && historyControlCharacteristic != nil && 
           historyDataCharacteristic != nil && deviceTimeCharacteristic != nil {
            startHistoryDataFlow()
        }
        
        // Mark connection as ready
        if !isConnected {
            isConnected = true
        }
    }
    
    // New method to handle the correct history data flow
    private func startHistoryDataFlow() {
        print("Starting history data flow...")
        isCancelled = false  // Reset cancel flag when starting
        loadingStateSubject.send(.loading)
        
        // Start connection quality monitoring
        startConnectionQualityMonitoring()

        // Step 1: Send 0xa00000 to switch to history mode
        guard let historyControlCharacteristic = historyControlCharacteristic else {
            print("History control characteristic not found.")
            return
        }
        
        print("Step 1: Setting history mode...")
        let modeCommand: [UInt8] = [0xa0, 0x00, 0x00]
        let modeData = Data(modeCommand)
        discoveredPeripheral?.writeValue(modeData, for: historyControlCharacteristic, type: .withResponse)
        
        // Step 2: Read device time 
        self.safeScheduleTimer(delay: 0.5) {
            print("Step 2: Reading device time...")
            if let deviceTimeCharacteristic = self.deviceTimeCharacteristic {
                self.discoveredPeripheral?.readValue(for: deviceTimeCharacteristic)
            }
            
            // Step 3: Get entry count
            self.safeScheduleTimer(delay: 0.5) {
                print("Step 3: Getting entry count...")
                let entryCountCommand: [UInt8] = [0x3c]  // Command to get entry count
                self.discoveredPeripheral?.writeValue(Data(entryCountCommand), for: historyControlCharacteristic, type: .withResponse)
                
                // After sending the command, read the history data characteristic
                self.safeScheduleTimer(delay: 0.5) {
                    print("Reading history data characteristic...")
                    if let historyDataCharacteristic = self.historyDataCharacteristic {
                        self.discoveredPeripheral?.readValue(for: historyDataCharacteristic)
                    }
                }
            }
        }
    }
    
    func blinkLED() {
        guard let peripheral = discoveredPeripheral else {
            print("Cannot blink LED: no peripheral found")
            return
        }
        
        // Check if already connected
        if (peripheral.state == .connected) {
            // If connected, send the command
            if let ledControlCharacteristic = ledControlCharacteristic {
                let blinkData = Data([0xfd, 0xff])
                peripheral.writeValue(blinkData, for: ledControlCharacteristic, type: .withResponse)
                print("LED blink command sent")
            } else {
                print("LED control characteristic not found")
            }
        } else {
            // If not connected, connect first then blink
            print("Device not connected. Connecting first...")
            centralManager.connect(peripheral, options: nil)
            // The blink command will be called after connecting in didConnect delegate
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Fehler beim Schreiben: \(error.localizedDescription)")
            // Bei Fehler Flag zurücksetzen und ggf. neu versuchen
            isRequestingData = false
            requestTimeoutTimer?.invalidate()
            return
        }

        if (characteristic.uuid == deviceModeChangeCharacteristicUUID) {
            print("Mode-Change erfolgreich, warte kurz...")
            
            // Verzögerung hinzufügen
            if let sensorChar = self.realTimeSensorValuesCharacteristic {
                print("Lese Sensordaten...")
                peripheral.readValue(for: sensorChar)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Flag zurücksetzen, da die Anfrage abgeschlossen ist (erfolgreich oder nicht)
        isRequestingData = false
        requestTimeoutTimer?.invalidate()
        
        guard error == nil else {
            print("Fehler beim Lesen: \(error!.localizedDescription)")
            return
        }

        if let value = characteristic.value {
            switch characteristic.uuid {
            case realTimeSensorValuesCharacteristicUUID:
                processAndValidateSensorData(value)
            case firmwareVersionCharacteristicUUID:
                Task {
                    await decodeFirmwareAndBattery(data: value)
                }
            case deviceNameCharacteristicUUID:
                decodeDeviceName(data: value)
            case deviceTimeCharacteristicUUID:
                decodeDeviceTime(data: value)
            case historicalSensorValuesCharacteristicUUID:
                decodeHistoryData(data: value)
            case entryCountCharacteristicUUID:
                decodeEntryCount(data: value)
            default:
                break
            }
        }
    }

    private func decodeEntryCount(data: Data) {
        if let count = decoder.decodeEntryCount(data: data) {
            totalEntries = count
            print("Total historical entries: \(totalEntries)")

            if (totalEntries > 0) {
                currentEntryIndex = 0
                // Update loading state
                loadingStateSubject.send(.loading)
                loadingProgressSubject.send((0, totalEntries))
                fetchHistoricalDataEntry(index: currentEntryIndex)
            } else {
                print("No historical entries available.")
                loadingStateSubject.send(.completed)
            }
        }
    }

    private func decodeRealTimeSensorValues(data: Data) async {
        guard let deviceUUID = self.deviceUUID else {
            print("No device UUID available for sensor data")
            return
        }
        
        if let sensorData = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: deviceUUID) {
            do {
                if let validateSensorData = try await PlantMonitorService.shared.validateSensorData(sensorData, deviceUUID: deviceUUID) {
                    // Convert to SensorData for backward compatibility with publishers
                    if let coreDataSensorData = validateSensorData.toCoreDataSensorData() {
                        sensorDataSubject.send(coreDataSensorData)
                    }
                }
            } catch {
                print("Error validating sensor data: \(error)")
            }
        }
    }

    private func decodeFirmwareAndBattery(data: Data) async {
        guard let (battery, firmware) = decoder.decodeFirmwareAndBattery(data: data),
              let deviceUUID = self.deviceUUID else { return }
        
        do {
            // Get current device data
            if let device = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) {
                // Update device with new battery and firmware info
                let updatedDevice = FlowerDeviceDTO(
                    id: device.id,
                    name: device.name,
                    uuid: device.uuid,
                    peripheralID: device.peripheralID,
                    battery: Int16(battery),
                    firmware: firmware,
                    isSensor: device.isSensor,
                    added: device.added,
                    lastUpdate: device.lastUpdate,
                    optimalRange: device.optimalRange,
                    potSize: device.potSize,
                    sensorData: device.sensorData
                )
                try await repositoryManager.flowerDeviceRepository.updateDevice(updatedDevice)
            }
        } catch {
            print("Error updating device firmware/battery: \(error)")
        }
    }

    private func decodeDeviceName(data: Data) {
        decoder.decodeDeviceName(data: data)
    }

    private func decodeDeviceTime(data: Data) {
        guard data.count >= 4 else {
            print("Device time data too short")
            return
        }
        
        // Extract seconds since device boot
        let secondsSinceBoot = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        
        // Calculate boot time by subtracting secondsSinceBoot from current time
        let now = Date()
        deviceBootTime = now.addingTimeInterval(-Double(secondsSinceBoot))
        
        print("Device has been running for \(secondsSinceBoot) seconds")
        print("Estimated boot time: \(deviceBootTime?.description ?? "unknown")")
        
        // Pass this information to the decoder for timestamp calculations
        decoder.setDeviceBootTime(bootTime: deviceBootTime, secondsSinceBoot: secondsSinceBoot)
    }

    // Add this to your FlowerCareManager class
    private func readHistoryMetadata() {
        guard let historyControlCharacteristic = historyControlCharacteristic,
            let historyDataCharacteristic = historyDataCharacteristic else {
            print("History characteristics not found.")
            return
        }
        
        // Send command to read history metadata (0x3c handle)
        let command = Data([0xA0, 0x00]) // Command to request history metadata
        discoveredPeripheral?.writeValue(command, for: historyControlCharacteristic, type: .withResponse)
        
        // After sending the command, read the history data characteristic
        self.safeScheduleTimer(delay: 0.2) {
            self.discoveredPeripheral?.readValue(for: historyDataCharacteristic)
        }
    }

    private func decodeHistoryData(data: Data) {
        // Check if operation has been cancelled
        if isCancelled {
            print("History data loading was cancelled")
            return
        }
        
        print("Received history data: \(data.count) bytes - Raw: \(data.map { String(format: "%02x", $0) }.joined())")
        
        // Check if this is metadata or an actual history entry
        if (data.count == 16 && currentEntryIndex == 0 && totalEntries == 0) {
            // This is likely metadata about history (entry count)
            if let (count, metadata) = decoder.decodeHistoryMetadata(data: data) {
                totalEntries = count
                print("Total historical entries from metadata: \(totalEntries)")
                
                // If there are entries, start fetching them
                if (totalEntries > 0) {
                    currentEntryIndex = 0
                    fetchHistoricalDataEntry(index: currentEntryIndex)
                } else {
                    print("No historical entries available.")
                }
            }
        } else {
            // This is an actual history entry
            if let historicalData = decoder.decodeHistoricalSensorData(data: data) {
                print("Decoded history entry \(currentEntryIndex): temp=\(historicalData.temperature)°C, moisture=\(historicalData.moisture)%, conductivity=\(historicalData.conductivity)µS/cm")
                
                historicalDataSubject.send(historicalData)
                
                // Update progress
                let nextIndex = currentEntryIndex + 1
                currentEntryIndex = nextIndex
                loadingProgressSubject.send((nextIndex, totalEntries))
                
                if nextIndex < totalEntries && !isCancelled {
                    // Add batch processing with longer delays between batches
                    let batchSize = 10
                    if nextIndex % batchSize == 0 {
                        print("Completed batch. Taking a break before next batch...")
                        // Take a longer break between batches to avoid disconnection
                        self.safeScheduleTimer(delay: 2.0) {
                            self.fetchHistoricalDataEntry(index: nextIndex)
                        }
                    } else {
                        // Increased delay between individual entries
                        self.safeScheduleTimer(delay: 0.5) {
                            self.fetchHistoricalDataEntry(index: nextIndex)
                        }
                    }
                } else if !isCancelled {
                    print("All historical data fetched successfully.")
                    loadingStateSubject.send(.completed)
                }
            } else {
                print("Failed to decode history entry \(currentEntryIndex)")
                
                // Error handling when decoding fails
                loadingStateSubject.send(.error("Failed to decode history entry \(currentEntryIndex), trying to skip this"))
                // Try to recover from failed decoding by skipping to the next entry
                let nextIndex = currentEntryIndex + 1
                if (nextIndex < totalEntries) {
                    print("Skipping to next entry...")
                    currentEntryIndex = nextIndex
                    self.safeScheduleTimer(delay: 0.5) {
                        self.fetchHistoricalDataEntry(index: nextIndex)
                    }
                }
            }
        }
    }

    func fetchEntryCount() {
        guard let historyControlCharacteristic = historyControlCharacteristic else {
            print("History control characteristic not found.")
            return
        }

        // First, send the mode change command to activate history mode
        let modeCommand: [UInt8] = [0xa0, 0x00, 0x00]
        let modeData = Data(modeCommand)
        discoveredPeripheral?.writeValue(modeData, for: historyControlCharacteristic, type: .withResponse)
        
        // After changing the mode, we'll read the entry count from the entry count characteristic
        if let entryCountCharacteristic = entryCountCharacteristic {
            discoveredPeripheral?.readValue(for: entryCountCharacteristic)
        }
    }

    private func fetchHistoricalDataEntry(index: Int) {
        // Check if operation has been cancelled
        if isCancelled {
            print("History data loading was cancelled")
            return
        }
        
        guard let peripheral = discoveredPeripheral,
              peripheral.state == .connected, // Check connection status
              let historyControlCharacteristic = historyControlCharacteristic,
              let historyDataCharacteristic = historyDataCharacteristic else {
            print("Cannot fetch history entry: device disconnected or characteristics unavailable")
            
            // If disconnected, try to reconnect if not cancelled
            if !isCancelled, let peripheral = discoveredPeripheral, peripheral.state != .connected {
                print("Device disconnected. Reconnecting...")
                centralManager.connect(peripheral, options: nil)
            }
            return
        }
        
        print("Fetching history entry \(index) of \(totalEntries)")
        
        // Format index correctly: 0xa1 + 2-byte index in little endian
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])
        
        // Write address to history control characteristic
        peripheral.writeValue(entryAddress, for: historyControlCharacteristic, type: .withResponse)
        
        // Increased delay to give the device more time to respond
        self.safeScheduleTimer(delay: 0.8) { // Increased delay
            // Check connection again before reading
            if peripheral.state == .connected {
                peripheral.readValue(for: historyDataCharacteristic)
            } else {
                print("Device disconnected before reading data")
                // Try to reconnect
                self.centralManager.connect(peripheral, options: nil)
            }
        }
    }
    
    // Add these new methods for validation
    
    private func processAndValidateSensorData(_ rawData: Data) {
        guard let deviceUUID = self.deviceUUID else {
            print("No device UUID available for sensor data processing")
            return
        }
        
        Task {
            // Decode the raw data
            if let decodedData = decoder.decodeRealTimeSensorValues(data: rawData, deviceUUID: deviceUUID) {
                do {
                    // Validate the sensor data
                    if let validatedData = try await PlantMonitorService.shared.validateSensorData(decodedData, deviceUUID: deviceUUID) {
                        // Reset retry counter on valid data
                        invalidDataRetryCount = 0
                        // Convert to SensorData for backward compatibility with publishers
                        if let coreDataSensorData = validatedData.toCoreDataSensorData() {
                            sensorDataSubject.send(coreDataSensorData)
                        }
                    } else {
                        // Data was invalid, retry if we haven't exceeded max attempts
                        handleInvalidData()
                    }
                } catch {
                    print("Error validating sensor data: \(error)")
                    handleInvalidData()
                }
            } else {
                // Decoding failed, retry
                handleInvalidData()
            }
        }
    }
    
    private func handleInvalidData() {
        invalidDataRetryCount += 1
        if (invalidDataRetryCount <= maxRetryAttempts) {
            print("Ungültige Sensordaten. Wiederhole... (Versuch \(invalidDataRetryCount)/\(maxRetryAttempts))")
            // Kurze Verzögerung vor erneutem Versuch
            self.safeScheduleTimer(delay: 1.0) {
                self.requestFreshSensorData()
            }
        } else {
            print("Konnte keine gültigen Daten nach \(maxRetryAttempts) Versuchen erhalten")
            invalidDataRetryCount = 0
        }
    }
    
    func requestFreshSensorData() {
        // Verhindere parallele Anfragen
        guard !isRequestingData else {
            print("Datenabfrage bereits im Gange, überspringe...")
            return
        }
        
        guard let peripheral = discoveredPeripheral,
              let modeChar = modeChangeCharacteristic,
              peripheral.state == .connected else {
            print("Gerät nicht bereit für Datenabfrage")
            return
        }
        
        // Setze das Flag und starte den Timeout-Timer
        isRequestingData = true
        startRequestTimeoutTimer()
        
        print("Sende Mode-Change Befehl...")
        let command: [UInt8] = [0xA0, 0x1F]
        peripheral.writeValue(Data(command), for: modeChar, type: .withResponse)
    }
    
    private func startRequestTimeoutTimer() {
        // Breche vorherigen Timer ab, falls vorhanden
        requestTimeoutTimer?.invalidate()
        
        // Starte neuen Timer
        requestTimeoutTimer = Timer.scheduledTimer(withTimeInterval: requestTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if (self.isRequestingData) {
                print("Timeout bei Sensorabfrage")
                self.isRequestingData = false
                self.invalidDataRetryCount += 1
                
                if (self.invalidDataRetryCount <= self.maxRetryAttempts) {
                    print("Versuche erneut... (Versuch \(self.invalidDataRetryCount)/\(self.maxRetryAttempts))")
                    self.requestFreshSensorData()
                } else {
                    print("Maximale Anzahl an Versuchen erreicht")
                    self.invalidDataRetryCount = 0
                }
            }
        }
    }

    // Add this property to your FlowerCareManager class
    private var isCancelled = false

    // Add this method to cancel the loading process
    func cancelHistoryDataLoading() {
        print("Cancelling history data loading")
        isCancelled = true
        
        // Stop connection monitoring
        stopConnectionQualityMonitoring()
        
        // Reset loading state
        loadingStateSubject.send(.idle)
        
        // Reset counters
        totalEntries = 0
        currentEntryIndex = 0
        
        disconnect()
    }

    // Public method to request live sensor data
    func requestLiveData() {
        liveDataRequested = true
        if isConnected && modeChangeCharacteristic != nil && realTimeSensorValuesCharacteristic != nil {
            requestFreshSensorData()
        } else if !isConnected {
            // Connect first if not connected
            if let deviceUUID = deviceUUID, let peripheral = discoveredPeripheral {
                centralManager.connect(peripheral, options: nil)
            } else if let deviceUUID = deviceUUID {
                connectToKnownDevice(deviceUUID: deviceUUID)
            }
        }
    }

    // Public method to request historical data
    func requestHistoricalData() {
        historicalDataRequested = true
        // Reset any previous loading state
        loadingStateSubject.send(.idle)
        totalEntries = 0
        currentEntryIndex = 0
        isCancelled = false
        
        if isConnected && historyControlCharacteristic != nil && 
           historyDataCharacteristic != nil && deviceTimeCharacteristic != nil {
            startHistoryDataFlow()
        } else if !isConnected {
            // Connect first if not connected
            if let deviceUUID = deviceUUID, let peripheral = discoveredPeripheral {
                centralManager.connect(peripheral, options: nil)
            } else if let deviceUUID = deviceUUID {
                connectToKnownDevice(deviceUUID: deviceUUID)
            }
        }
    }

    // Add this method to your class

    private func checkConnectionQuality(completion: @escaping (ConnectionQuality) -> Void) {
        guard let peripheral = discoveredPeripheral, peripheral.state == .connected else {
            connectionQualitySubject.send(.unknown)
            completion(.unknown)
            return
        }
        
        peripheral.readRSSI()
        
        // We'll capture the first RSSI update after requesting it
        rssiCheckCompletion = completion
    }

    private func evaluateConnectionQuality(rssi: NSNumber) -> ConnectionQuality {
        let rssiValue = rssi.intValue
        
        // RSSI evaluation thresholds
        // Generally:
        // -50 to 0 dBm = Excellent
        // -70 to -50 dBm = Good
        // -80 to -70 dBm = Fair
        // Less than -80 dBm = Poor
        
        if rssiValue >= -65 {
            return .good
        } else if rssiValue >= -80 {
            return .fair
        } else {
            return .poor
        }
    }

    // Property to store the completion handler
    private var rssiCheckCompletion: ((ConnectionQuality) -> Void)?

    // Add this method to your CBPeripheralDelegate implementations

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let quality: ConnectionQuality
        
        if let error = error {
            print("Failed to read RSSI: \(error.localizedDescription)")
            quality = .unknown
        } else {
            quality = evaluateConnectionQuality(rssi: RSSI)
            print("Current RSSI: \(RSSI) dBm - Connection quality: \(quality.description)")
        }
        
        // Update the published value
        connectionQualitySubject.send(quality)
        
        // Call the completion handler if it exists
        if let completion = rssiCheckCompletion {
            completion(quality)
            rssiCheckCompletion = nil
        }
    }

    // Add this method to monitor connection during history retrieval

    private var connectionMonitorTimer: Timer?

    private func startConnectionQualityMonitoring() {
        stopConnectionQualityMonitoring()
        
        connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, 
                  self.totalEntries > 0, 
                  self.currentEntryIndex < self.totalEntries,
                  !self.isCancelled else {
                self?.stopConnectionQualityMonitoring()
                return
            }
            
            self.discoveredPeripheral?.readRSSI()
        }
    }

    private func stopConnectionQualityMonitoring() {
        connectionMonitorTimer?.invalidate()
        connectionMonitorTimer = nil
    }
}
