//
//  FlowerManager.swift
//  GrowGuard
//
//  Restored from Beta-270325 with full BLE functionality and DTO compatibility
//

import Foundation
import CoreBluetooth
import Combine
import OSLog


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
    var authenticationCharacteristic: CBCharacteristic?
    var isConnected = false
    
    // Authentication properties
    private var isAuthenticated = false
    private var authenticationStep = 0
    private var expectedResponse: Data?
    
    private var isScanning = false
    private var deviceUUID: String? // Changed from FlowerDevice to UUID string
    private var totalEntries: Int = 0
    private var currentEntryIndex: Int = 0
    private var invalidDataRetryCount = 0
    private let maxRetryAttempts = 3
    
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()
    private let deviceUpdateSubject = PassthroughSubject<FlowerDeviceDTO, Never>()

    private let decoder = SensorDataDecoder()

    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        return sensorDataSubject.eraseToAnyPublisher()
    }
    
    var historicalDataPublisher: AnyPublisher<HistoricalSensorData, Never> {
        return historicalDataSubject.eraseToAnyPublisher()
    }
    
    var deviceUpdatePublisher: AnyPublisher<FlowerDeviceDTO, Never> {
        return deviceUpdateSubject.eraseToAnyPublisher()
    }
    
    static var shared = FlowerCareManager()

    // Neues Flag zur Vermeidung doppelter Anfragen
    private var isRequestingData = false
    private var requestTimeoutTimer: Timer?
    private let requestTimeout = 10.0  // Timeout in Sekunden

    private var deviceBootTime: Date?

    // Add these properties to your FlowerCareManager class
    private let loadingProgressSubject = CurrentValueSubject<(current: Int, total: Int), Never>((0, 0))
    private let loadingStateSubject = CurrentValueSubject<LoadingState, Never>(.idle)

    // Connection quality properties (from beta)
    private let connectionQualitySubject = CurrentValueSubject<ConnectionQuality, Never>(.unknown)
    private let connectionStateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)

    // Request flags
    private var liveDataRequested = false
    private var historicalDataRequested = false
    
    // Enhanced error handling
    private var operationRetryCount = 0
    private let maxOperationRetries = 3
    private var errorRecoveryTimer: Timer?
    
    // History data flow control
    private var isHistoryFlowActive = false
    private var historyFlowTimers: [Timer] = []

    var loadingStatePublisher: AnyPublisher<LoadingState, Never> {
        loadingStateSubject.eraseToAnyPublisher()
    }

    var loadingProgressPublisher: AnyPublisher<(current: Int, total: Int), Never> {
        loadingProgressSubject.eraseToAnyPublisher()
    }

    // Connection quality monitoring
    private var rssiCheckCompletion: ((ConnectionQuality) -> Void)?

    // Public publishers
    var connectionQualityPublisher: AnyPublisher<ConnectionQuality, Never> {
        return connectionQualitySubject.eraseToAnyPublisher()
    }
    
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        return connectionStateSubject.eraseToAnyPublisher()
    }
    
    // Compatibility publishers
    var rssiDistancePublisher: AnyPublisher<String, Never> {
        connectionQualityPublisher
            .map { quality in
                switch quality {
                case .good: return "Close (Good signal)"
                case .fair: return "Medium (Fair signal)"
                case .poor: return "Far (Poor signal)"
                case .unknown: return "Unknown"
                }
            }
            .eraseToAnyPublisher()
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // Updated to accept UUID string instead of FlowerDevice
    func startScanning(deviceUUID: String) {
        self.deviceUUID = deviceUUID
        guard let centralManager = centralManager else { return }
        if (!isScanning && centralManager.state == .poweredOn) {
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            isScanning = true
            AppLogger.ble.bleConnection("Scanning started for device \(deviceUUID)")
        }
    }

    func stopScanning() {
        guard let centralManager = centralManager else { return }
        if (isScanning) {
            centralManager.stopScan()
            isScanning = false
            AppLogger.ble.bleConnection("Scanning stopped")
        }
    }
    
    // Updated to accept UUID string instead of FlowerDevice
    func connectToKnownDevice(deviceUUID: String) {
        guard let uuid = UUID(uuidString: deviceUUID) else {
            AppLogger.ble.bleError("Invalid device UUID: \(deviceUUID)")
            connectionStateSubject.send(.error(.deviceNotFound))
            return
        }
        
        connectionStateSubject.send(.connecting)
        self.deviceUUID = deviceUUID
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            discoveredPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
            AppLogger.ble.bleConnection("Connecting to known device: \(deviceUUID)")
        } else {
            AppLogger.ble.bleConnection("Known device not found, starting scan for: \(deviceUUID)")
            startScanning(deviceUUID: deviceUUID)
        }
    }
    
    func disconnect() {
        guard let centralManager = centralManager, let peripheral = discoveredPeripheral else { return }

        connectionStateSubject.send(.disconnected)
        centralManager.cancelPeripheralConnection(peripheral)
        AppLogger.ble.bleConnection("Disconnecting from peripheral: \(peripheral.identifier)")

        // Clean up history flow
        cleanupHistoryFlow()
        
        // Reset properties
        discoveredPeripheral = nil
        realTimeSensorValuesCharacteristic = nil
        historyControlCharacteristic = nil
        historyDataCharacteristic = nil
        deviceTimeCharacteristic = nil
        entryCountCharacteristic = nil
        authenticationCharacteristic = nil

        isScanning = false
        deviceUUID = nil
        totalEntries = 0
        currentEntryIndex = 0
        isConnected = false
        isAuthenticated = false
        authenticationStep = 0
        
        // Reset request flags
        liveDataRequested = false
        historicalDataRequested = false
        
        // Reset error state
        resetErrorState()
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
    
    func startPassiveListening() {
        guard let centralManager = centralManager else { return }
        if (!isScanning && centralManager.state == .poweredOn) {
            // Start passive scanning for advertisements without connecting
            let options: [String: Any] = [
                CBCentralManagerScanOptionAllowDuplicatesKey: true,
                CBCentralManagerScanOptionSolicitedServiceUUIDsKey: [flowerCareServiceUUID]
            ]
            centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: options)
            isScanning = true
            AppLogger.ble.info("🔊 Passive listening started")
            
            // Set a timer to stop passive listening after 60 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) {
                self.stopPassiveListening()
            }
        }
    }
    
    func stopPassiveListening() {
        guard let centralManager = centralManager else { return }
        if (isScanning) {
            centralManager.stopScan()
            isScanning = false
            AppLogger.ble.info("🔇 Passive listening stopped")
        }
    }
    
    private func processAdvertisementData(_ data: [String: Any], rssi: NSNumber) {
        // Process manufacturer data if available
        if let manufacturerData = data[CBAdvertisementDataManufacturerDataKey] as? Data {
            processManufacturerData(manufacturerData, rssi: rssi)
        }
        
        // Process service data if available  
        if let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (serviceUUID, data) in serviceData {
                processServiceData(data, serviceUUID: serviceUUID, rssi: rssi)
            }
        }
    }
    
    private func processManufacturerData(_ data: Data, rssi: NSNumber) {
        // Check if this is a Xiaomi device (manufacturer ID 0x038F)
        guard data.count >= 2 else { return }
        
        let manufacturerID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        if manufacturerID == 0x038F && data.count >= 8 {
            // This might be MiBeacon format
            AppLogger.ble.bleData("📡 Received MiBeacon advertisement: \(data.map { String(format: "%02x", $0) }.joined()) RSSI: \(rssi)")
            
            // Try to decode advertisement data directly
            if let deviceUUID = deviceUUID,
               let sensorData = decoder.decodeMiBeaconAdvertisement(data: data, deviceUUID: deviceUUID) {
                Task {
                    do {
                        // Validate the sensor data directly
                        if let validatedData = try await PlantMonitorService.shared.validateSensorData(sensorData, deviceUUID: deviceUUID) {
                            // Convert to Core Data format for backward compatibility
                            if let coreDataSensorData = validatedData.toCoreDataSensorData() {
                                DispatchQueue.main.async {
                                    self.sensorDataSubject.send(coreDataSensorData)
                                }
                            }
                        }
                    } catch {
                        print("Error validating MiBeacon advertisement data: \(error)")
                    }
                }
            }
        }
    }
    
    private func processServiceData(_ data: Data, serviceUUID: CBUUID, rssi: NSNumber) {
        if serviceUUID == flowerCareServiceUUID && data.count >= 8 {
            AppLogger.ble.bleData("📡 Received FlowerCare service data: \(data.map { String(format: "%02x", $0) }.joined()) RSSI: \(rssi)")
            
            // Try to decode service advertisement data
            if let deviceUUID = deviceUUID,
               let sensorData = decoder.decodeServiceAdvertisement(data: data, deviceUUID: deviceUUID) {
                Task {
                    do {
                        // Validate the sensor data directly
                        if let validatedData = try await PlantMonitorService.shared.validateSensorData(sensorData, deviceUUID: deviceUUID) {
                            // Convert to Core Data format for backward compatibility
                            if let coreDataSensorData = validatedData.toCoreDataSensorData() {
                                DispatchQueue.main.async {
                                    self.sensorDataSubject.send(coreDataSensorData)
                                }
                            }
                        }
                    } catch {
                        print("Error validating service advertisement data: \(error)")
                    }
                }
            }
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == .poweredOff) {
            AppLogger.ble.bleError("Bluetooth is not available - state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // First, process any advertisement data for passive monitoring
        if (peripheral.identifier.uuidString == deviceUUID) {
            processAdvertisementData(advertisementData, rssi: RSSI)
        }
        
        // If we're actively looking for a device to connect, proceed with connection
        if (peripheral.identifier.uuidString == deviceUUID && !isConnected) {
            centralManager.stopScan()
            discoveredPeripheral = peripheral
            discoveredPeripheral?.delegate = self
            centralManager.connect(discoveredPeripheral!, options: nil)
            AppLogger.ble.bleConnection("Flower Care Sensor found: \(peripheral.identifier). Connecting...")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLogger.ble.bleConnection("Connected to: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        connectionStateSubject.send(.connected)
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        
        // Wichtig: Vielleicht muss zuerst eine Authentifizierung erfolgen
        // Manche Geräte benötigen einen speziellen Handshake
    }

    // Add this delegate method to detect disconnections
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLogger.ble.bleConnection("Disconnected from peripheral: \(peripheral.identifier)")
        
        // Update connection state
        connectionStateSubject.send(.disconnected)
        isConnected = false
        
        // Pause any ongoing operations
        let wasRequestingData = isRequestingData
        isRequestingData = false
        
        // Clean up any ongoing operations
        cleanupHistoryFlow()
        
        // Only reconnect for historical data if we haven't completed live data successfully
        // and there's actually historical data processing in progress
        if historicalDataRequested && totalEntries > 0 && currentEntryIndex < totalEntries && !isCancelled {
            AppLogger.ble.info("📊 Disconnected during history retrieval, reconnecting...")
            // Delay reconnection slightly to allow device to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if let deviceUUID = self.deviceUUID, !self.isCancelled {
                    self.connectToKnownDevice(deviceUUID: deviceUUID)
                }
            }
        } else if historicalDataRequested && totalEntries == 0 && !wasRequestingData && !isCancelled {
            AppLogger.ble.info("📊 Live data completed, will reconnect for historical data...")
            // Only reconnect if we're not in the middle of a live data request
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if let deviceUUID = self.deviceUUID, !self.isCancelled && self.historicalDataRequested {
                    AppLogger.ble.info("📊 Reconnecting specifically for historical data")
                    self.connectToKnownDevice(deviceUUID: deviceUUID)
                }
            }
        } else if historicalDataRequested {
            AppLogger.ble.info("📊 Not reconnecting - wasRequestingData: \(wasRequestingData), totalEntries: \(self.totalEntries), currentIndex: \(self.currentEntryIndex)")
        }
        // Handle other disconnection scenarios
        else if wasRequestingData && !isCancelled {
            AppLogger.ble.info("Disconnected during sensor data request")
            handleBLEError(.deviceDisconnected) {
                self.requestFreshSensorData()
            }
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
                case entryCountCharacteristicUUID:
                    entryCountCharacteristic = characteristic
                case authenticationCharacteristicUUID:
                    authenticationCharacteristic = characteristic
                    AppLogger.ble.info("🔐 Authentication characteristic discovered")
                default:
                    break
                }
            }
        }

        // Sequential operation handling - prioritize live data first, then historical data
        if liveDataRequested && modeChangeCharacteristic != nil && realTimeSensorValuesCharacteristic != nil {
            AppLogger.ble.info("📊 Starting live data request first")
            requestFreshSensorData()
        } else if historicalDataRequested && !liveDataRequested && historyControlCharacteristic != nil && 
                  historyDataCharacteristic != nil && deviceTimeCharacteristic != nil {
            AppLogger.ble.info("🔄 All required characteristics found for history data (no live data requested)")
            // For now, let's skip authentication and see if FlowerCare works without it
            // Many FlowerCare devices don't actually require authentication
            startHistoryDataFlow()
        } else if historicalDataRequested && liveDataRequested {
            AppLogger.ble.info("📊 Both live and historical data requested - will start historical after live data completes")
        }
        
        // Mark connection as ready
        if !isConnected {
            isConnected = true
            // If no authentication is needed and we're ready to proceed
            if authenticationCharacteristic == nil || isAuthenticated {
                connectionStateSubject.send(.ready)
            }
        }
    }
    
    // MARK: - Authentication Methods
    private func startAuthentication() {
        guard let authCharacteristic = authenticationCharacteristic else {
            AppLogger.ble.info("🔐 No authentication characteristic found, proceeding without auth")
            startHistoryDataFlow()
            return
        }
        
        AppLogger.ble.info("🔐 Starting FlowerCare authentication...")
        connectionStateSubject.send(.authenticating)
        authenticationStep = 1
        isAuthenticated = false
        
        // Step 1: Send authentication challenge
        let challengeData = Data([0x90, 0xCA, 0x85, 0xDE])
        AppLogger.ble.bleData("🔐 Sending auth challenge: \(challengeData.map { String(format: "%02x", $0) }.joined())")
        discoveredPeripheral?.writeValue(challengeData, for: authCharacteristic, type: .withResponse)
        
        // Set expected response for validation
        expectedResponse = Data([0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        // Set a timeout for authentication
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if self.authenticationStep > 0 && !self.isAuthenticated {
                AppLogger.ble.bleError("🔐 Authentication timeout, proceeding without auth")
                self.authenticationStep = 0
                self.startHistoryDataFlow()
            }
        }
    }
    
    private func handleAuthenticationResponse(_ data: Data) {
        AppLogger.ble.bleData("🔐 Authentication response: \(data.map { String(format: "%02x", $0) }.joined())")
        
        switch authenticationStep {
        case 1:
            // Validate challenge response
            if data.starts(with: expectedResponse?.prefix(4) ?? Data()) {
                AppLogger.ble.info("✅ Authentication challenge successful")
                authenticationStep = 2
                
                // Step 2: Send final authentication key
                let finalKey = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
                discoveredPeripheral?.writeValue(finalKey, for: authenticationCharacteristic!, type: .withResponse)
            } else {
                AppLogger.ble.bleError("❌ Authentication challenge failed")
                handleBLEError(.authenticationFailed) {
                    // Authentication failures are typically not recoverable
                    // but we can try once more
                    self.startAuthentication()
                }
            }
            
        case 2:
            // Final authentication step
            AppLogger.ble.info("✅ Authentication completed successfully")
            isAuthenticated = true
            authenticationStep = 0
            connectionStateSubject.send(.ready)
            
            // Now start the actual history data flow
            startHistoryDataFlow()
            
        default:
            AppLogger.ble.bleError("❌ Unexpected authentication step: \(authenticationStep)")
        }
    }

    // New method to handle the correct history data flow (from Beta-270325)
    private func startHistoryDataFlow() {
        // Prevent multiple concurrent history flows
        guard !isHistoryFlowActive else {
            AppLogger.ble.info("⚠️ History flow already active, ignoring request")
            return
        }
        
        AppLogger.ble.info("🔄 Starting history data flow for device: \(self.deviceUUID ?? "unknown")")
        isHistoryFlowActive = true
        isCancelled = false  // Reset cancel flag when starting
        loadingStateSubject.send(.loading)
        
        // Start connection quality monitoring
        startConnectionQualityMonitoring()

        // Step 1: Send 0xa00000 to switch to history mode
        guard let historyControlCharacteristic = historyControlCharacteristic,
              let peripheral = discoveredPeripheral,
              peripheral.state == .connected else {
            AppLogger.ble.bleError("Cannot start history flow: device not connected or characteristic missing")
            isHistoryFlowActive = false
            return
        }
        
        AppLogger.ble.bleData("Step 1: Setting history mode (0xa00000)")
        let modeCommand: [UInt8] = [0xa0, 0x00, 0x00]
        let modeData = Data(modeCommand)
        peripheral.writeValue(modeData, for: historyControlCharacteristic, type: .withResponse)
        
        // Step 2: Read device time (give device more time to process mode change)
        let step2Timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] timer in
            guard let self = self, 
                  let peripheral = self.discoveredPeripheral,
                  peripheral.state == .connected else {
                AppLogger.ble.bleError("Device disconnected before step 2")
                self?.cleanupHistoryFlow()
                return
            }
            
            AppLogger.ble.bleData("Step 2: Reading device time")
            if let deviceTimeCharacteristic = self.deviceTimeCharacteristic {
                peripheral.readValue(for: deviceTimeCharacteristic)
            }
            
            // Step 3: Get entry count (more conservative timing)
            let step3Timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] timer in
                guard let self = self,
                      let peripheral = self.discoveredPeripheral,
                      peripheral.state == .connected else {
                    AppLogger.ble.bleError("Device disconnected before step 3")
                    self?.cleanupHistoryFlow()
                    return
                }
                
                AppLogger.ble.bleData("Step 3: Getting entry count (0x3c command)")
                let entryCountCommand: [UInt8] = [0x3c]  // Command to get entry count
                peripheral.writeValue(Data(entryCountCommand), for: historyControlCharacteristic, type: .withResponse)
                
                // After sending the command, read the history data characteristic (longer delay)
                let step4Timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] timer in
                    guard let self = self,
                          let peripheral = self.discoveredPeripheral,
                          peripheral.state == .connected else {
                        AppLogger.ble.bleError("Device disconnected before step 4")
                        self?.cleanupHistoryFlow()
                        return
                    }
                    
                    AppLogger.ble.bleData("Reading history data characteristic")
                    if let historyDataCharacteristic = self.historyDataCharacteristic {
                        peripheral.readValue(for: historyDataCharacteristic)
                    }
                }
                self.historyFlowTimers.append(step4Timer)
            }
            self.historyFlowTimers.append(step3Timer)
        }
        historyFlowTimers.append(step2Timer)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let entryCountCharacteristic = self.entryCountCharacteristic {
                self.discoveredPeripheral?.readValue(for: entryCountCharacteristic)
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
            AppLogger.ble.bleError("❌ Write error: \(error.localizedDescription)")
            // Bei Fehler Flag zurücksetzen und ggf. neu versuchen
            isRequestingData = false
            requestTimeoutTimer?.invalidate()
            return
        }

        if (characteristic.uuid == deviceModeChangeCharacteristicUUID) {
            AppLogger.ble.bleData("✅ Mode change successful, reading sensor data...")
            
            // Verzögerung hinzufügen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let peripheral = self.discoveredPeripheral,
                      peripheral.state == .connected,
                      let sensorChar = self.realTimeSensorValuesCharacteristic else {
                    AppLogger.ble.bleError("❌ Cannot read sensor data: device disconnected or characteristic missing")
                    self.isRequestingData = false
                    return
                }
                
                AppLogger.ble.bleData("📊 Reading fresh sensor data")
                peripheral.readValue(for: sensorChar)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Flag zurücksetzen, da die Anfrage abgeschlossen ist (erfolgreich oder nicht)
        isRequestingData = false
        requestTimeoutTimer?.invalidate()
        
        guard error == nil else {
            AppLogger.ble.bleError("❌ Read error: \(error!.localizedDescription)")
            return
        }

        if let value = characteristic.value {
            switch characteristic.uuid {
            case realTimeSensorValuesCharacteristicUUID:
                processAndValidateSensorData(value)
            case firmwareVersionCharacteristicUUID:
                decodeFirmwareAndBattery(data: value)
            case deviceNameCharacteristicUUID:
                decodeDeviceName(data: value)
            case deviceTimeCharacteristicUUID:
                decodeDeviceTime(data: value)
            case historicalSensorValuesCharacteristicUUID:
                decodeHistoryData(data: value)
            case entryCountCharacteristicUUID:
                decodeEntryCount(data: value)
            case authenticationCharacteristicUUID:
                handleAuthenticationResponse(value)
            default:
                break
            }
        }
    }

    private func decodeEntryCount(data: Data) {
        if let count = decoder.decodeEntryCount(data: data) {
            totalEntries = count
            AppLogger.ble.info("📊 Total historical entries available: \(self.totalEntries)")

            if (totalEntries > 0) {
                // Get the last synced index for incremental sync
                Task {
                    do {
                        var startIndex = 0
                        if let deviceUUID = deviceUUID,
                           let deviceDTO = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: deviceUUID) {
                            let lastSyncedIndex = deviceDTO.lastHistoryIndex
                            
                            // If we've already synced all entries, start from 0 for a full refresh
                            if lastSyncedIndex >= totalEntries {
                                startIndex = 0
                                AppLogger.ble.info("🔄 All entries already synced, starting full refresh from index 0 of \(self.totalEntries)")
                            } else {
                                // Start from the last synced index to get new entries
                                startIndex = lastSyncedIndex
                                AppLogger.ble.info("🔄 Starting incremental sync from index \(startIndex) of \(self.totalEntries)")
                            }
                        } else {
                            AppLogger.ble.info("🔄 Starting full sync from index 0")
                        }
                        
                        DispatchQueue.main.async {
                            self.currentEntryIndex = startIndex
                            
                            // Check if there are actually new entries to fetch
                            if startIndex < self.totalEntries {
                                // Update loading state
                                self.loadingStateSubject.send(.loading)
                                self.loadingProgressSubject.send((startIndex, self.totalEntries))
                                self.fetchHistoricalDataEntry(index: startIndex)
                            } else {
                                AppLogger.ble.info("ℹ️ No new historical entries to sync")
                                self.loadingStateSubject.send(.completed)
                                
                                // Mark historical data as completed
                                self.historicalDataRequested = false
                                self.cleanupHistoryFlow()
                                
                                // Disconnect to save battery
                                AppLogger.ble.info("🔌 Disconnecting after no new entries to sync")
                                self.disconnect()
                            }
                        }
                    } catch {
                        AppLogger.ble.bleError("Error getting device for incremental sync: \(error)")
                        DispatchQueue.main.async {
                            self.currentEntryIndex = 0
                            self.loadingStateSubject.send(.loading)
                            self.loadingProgressSubject.send((0, self.totalEntries))
                            self.fetchHistoricalDataEntry(index: 0)
                        }
                    }
                }
            } else {
                AppLogger.ble.info("ℹ️ No historical entries available for device")
                loadingStateSubject.send(.completed)
            }
        }
    }

    private func decodeFirmwareAndBattery(data: Data) {
        guard let (battery, firmware) = decoder.decodeFirmwareAndBattery(data: data) else { return }
        
        AppLogger.sensor.info("🔋 Device battery: \(battery)%, firmware: \(firmware)")
        
        // Update device battery level in database
        guard let deviceUUID = self.deviceUUID else { return }
        
        Task {
            do {
                guard var deviceDTO = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                    print("Device not found for UUID: \(deviceUUID)")
                    return
                }
                
                // Update battery level (keep existing lastUpdate - don't change it for firmware/battery reads)
                deviceDTO = FlowerDeviceDTO(
                    id: deviceDTO.id,
                    name: deviceDTO.name,
                    uuid: deviceDTO.uuid,
                    peripheralID: deviceDTO.peripheralID,
                    battery: Int16(battery),
                    firmware: firmware,
                    isSensor: deviceDTO.isSensor,
                    added: deviceDTO.added,
                    lastUpdate: deviceDTO.lastUpdate, // Keep existing lastUpdate
                    optimalRange: deviceDTO.optimalRange,
                    potSize: deviceDTO.potSize,
                    selectedFlower: deviceDTO.selectedFlower,
                    sensorData: deviceDTO.sensorData
                )
                
                try await RepositoryManager.shared.flowerDeviceRepository.updateDevice(deviceDTO)
                print("Successfully updated battery level to \(battery)% for device \(deviceUUID)")
                
                // Publish the updated device
                deviceUpdateSubject.send(deviceDTO)
            } catch {
                print("Error updating device battery: \(error)")
            }
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
        
        AppLogger.ble.info("⏱️ Device uptime: \(secondsSinceBoot) seconds")
        AppLogger.ble.info("🕰️ Estimated boot time: \(self.deviceBootTime?.description ?? "unknown")")
        
        // Pass this information to the decoder for timestamp calculations
        decoder.setDeviceBootTime(bootTime: deviceBootTime, secondsSinceBoot: secondsSinceBoot)
    }

    // MARK: - Incremental Sync Helper
    private func updateLastHistoryIndex(_ index: Int) {
        guard let deviceUUID = deviceUUID else { return }
        
        Task {
            do {
                guard var deviceDTO = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                    AppLogger.ble.bleError("Device not found for UUID: \(deviceUUID)")
                    return
                }
                
                // Update only the lastHistoryIndex
                let updatedDTO = FlowerDeviceDTO(
                    id: deviceDTO.id,
                    name: deviceDTO.name,
                    uuid: deviceDTO.uuid,
                    peripheralID: deviceDTO.peripheralID,
                    battery: deviceDTO.battery,
                    firmware: deviceDTO.firmware,
                    isSensor: deviceDTO.isSensor,
                    added: deviceDTO.added,
                    lastUpdate: deviceDTO.lastUpdate,
                    lastHistoryIndex: index,
                    optimalRange: deviceDTO.optimalRange,
                    potSize: deviceDTO.potSize,
                    selectedFlower: deviceDTO.selectedFlower,
                    sensorData: deviceDTO.sensorData
                )
                
                try await RepositoryManager.shared.flowerDeviceRepository.updateDevice(updatedDTO)
                AppLogger.ble.info("📝 Updated lastHistoryIndex to \(index) for device \(deviceUUID)")
            } catch {
                AppLogger.ble.bleError("Error updating lastHistoryIndex: \(error)")
            }
        }
    }
    
    private func resetLastHistoryIndex(for deviceUUID: String) async {
        do {
            guard var deviceDTO = try await RepositoryManager.shared.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                AppLogger.ble.bleError("Device not found for UUID: \(deviceUUID)")
                return
            }
            
            // Reset lastHistoryIndex to 0 to force full sync
            let updatedDTO = FlowerDeviceDTO(
                id: deviceDTO.id,
                name: deviceDTO.name,
                uuid: deviceDTO.uuid,
                peripheralID: deviceDTO.peripheralID,
                battery: deviceDTO.battery,
                firmware: deviceDTO.firmware,
                isSensor: deviceDTO.isSensor,
                added: deviceDTO.added,
                lastUpdate: deviceDTO.lastUpdate,
                lastHistoryIndex: 0,
                optimalRange: deviceDTO.optimalRange,
                potSize: deviceDTO.potSize,
                selectedFlower: deviceDTO.selectedFlower,
                sensorData: deviceDTO.sensorData
            )
            
            try await RepositoryManager.shared.flowerDeviceRepository.updateDevice(updatedDTO)
            AppLogger.ble.info("📝 Reset lastHistoryIndex to 0 for device \(deviceUUID) - forcing full sync")
        } catch {
            AppLogger.ble.bleError("Error resetting lastHistoryIndex: \(error)")
        }
    }

    private func handleBLEError(_ error: BLEError, operation: @escaping () -> Void) {
        AppLogger.ble.bleError("🚨 BLE Error occurred: \(error.localizedDescription)")
        
        if error.isRecoverable && operationRetryCount < maxOperationRetries {
            operationRetryCount += 1
            let retryDelay = TimeInterval(operationRetryCount * 2) // Exponential backoff
            
            AppLogger.ble.info("🔄 Attempting recovery... (attempt \(self.operationRetryCount)/\(self.maxOperationRetries))")
            
            errorRecoveryTimer?.invalidate()
            errorRecoveryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                
                switch error {
                case .deviceDisconnected, .connectionFailed:
                    self.attemptReconnection {
                        operation()
                    }
                case .timeout:
                    operation()
                case .dataDecodingFailed, .invalidResponse, .insufficientDataLength:
                    operation()
                default:
                    operation()
                }
            }
        } else {
            // Maximum retries reached or error is not recoverable
            operationRetryCount = 0
            loadingStateSubject.send(.error(error.localizedDescription))
        }
    }
    
    private func attemptReconnection(completion: @escaping () -> Void) {
        guard let peripheral = discoveredPeripheral else {
            handleBLEError(.deviceNotFound, operation: completion)
            return
        }
        
        if peripheral.state != .connected {
            AppLogger.ble.info("🔄 Attempting to reconnect to peripheral...")
            centralManager.connect(peripheral, options: nil)
            
            // Set a timeout for reconnection
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                if peripheral.state == .connected {
                    AppLogger.ble.info("✅ Reconnection successful")
                    completion()
                } else {
                    self.handleBLEError(.connectionFailed, operation: completion)
                }
            }
        } else {
            completion()
        }
    }
    
    private func resetErrorState() {
        operationRetryCount = 0
        errorRecoveryTimer?.invalidate()
        errorRecoveryTimer = nil
    }
    
    // MARK: - History Flow Control
    private func cleanupHistoryFlow() {
        AppLogger.ble.info("🧹 Cleaning up history flow")
        isHistoryFlowActive = false
        
        // Cancel all pending timers
        for timer in historyFlowTimers {
            timer.invalidate()
        }
        historyFlowTimers.removeAll()
        
        // Cancel any timeout timers
        requestTimeoutTimer?.invalidate()
        requestTimeoutTimer = nil
    }
    
    // MARK: - Sequential Operation Handling
    private func onLiveDataCompleted() {
        AppLogger.ble.info("✅ Live data completed successfully")
        
        // If historical data was also requested, give device time to settle after live data
        if historicalDataRequested {
            AppLogger.ble.info("📊 Historical data requested - giving device time to settle after live data")
            
            if isConnected && 
               historyControlCharacteristic != nil && 
               historyDataCharacteristic != nil && 
               deviceTimeCharacteristic != nil {
                
                AppLogger.ble.info("📊 Device ready - starting historical data flow after 3 second settling period")
                
                // Give device significant time to settle after live data before switching modes
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.isConnected && self.historicalDataRequested && !self.isHistoryFlowActive {
                        AppLogger.ble.info("📊 Starting historical data flow after settling period")
                        self.startHistoryDataFlow()
                    } else {
                        AppLogger.ble.info("📊 Cannot start history flow - connected: \(self.isConnected), requested: \(self.historicalDataRequested), active: \(self.isHistoryFlowActive)")
                    }
                }
            } else {
                AppLogger.ble.info("📊 Device not ready for immediate history flow - will start on next connection")
            }
        } else {
            AppLogger.ble.info("📊 Live data completed, no historical data requested")
            // Give device time to settle before disconnecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.disconnect()
            }
        }
    }

    // Add the rest of the missing methods from beta...
    
    private var isCancelled = false
    
    
    // MARK: - Test Access Properties (Internal for testing)
    #if DEBUG
    internal var testTotalEntries: Int {
        get { return totalEntries }
        set { totalEntries = newValue }
    }
    
    internal var testCurrentEntryIndex: Int {
        get { return currentEntryIndex }
        set { currentEntryIndex = newValue }
    }
    
    internal var testIsCancelled: Bool {
        get { return isCancelled }
        set { isCancelled = newValue }
    }
    
    internal var testDeviceBootTime: Date? {
        return deviceBootTime
    }
    
    internal var testLoadingStateSubject: CurrentValueSubject<LoadingState, Never> {
        return loadingStateSubject
    }
    
    internal var testLoadingProgressSubject: CurrentValueSubject<(current: Int, total: Int), Never> {
        return loadingProgressSubject
    }
    
    internal var testHistoricalDataSubject: PassthroughSubject<HistoricalSensorData, Never> {
        return historicalDataSubject
    }
    
    internal func testDecodeEntryCount(data: Data) {
        decodeEntryCount(data: data)
    }
    
    internal func testDecodeDeviceTime(data: Data) {
        decodeDeviceTime(data: data)
    }
    
    internal func testDecodeHistoryData(data: Data) {
        decodeHistoryData(data: data)
    }
    #endif


    func cancelHistoryDataLoading() {
        AppLogger.ble.info("🚫 Cancelling history data loading for device: \(self.deviceUUID ?? "unknown")")
        isCancelled = true
        
        // Clean up history flow
        cleanupHistoryFlow()
        
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
        resetErrorState()
        liveDataRequested = true
        AppLogger.ble.info("📊 Live data requested")
        if isConnected && modeChangeCharacteristic != nil && realTimeSensorValuesCharacteristic != nil {
            requestFreshSensorData()
        } else if !isConnected {
            // Connect first if not connected
            if let deviceUUID = deviceUUID {
                connectToKnownDevice(deviceUUID: deviceUUID)
            }
        }
    }

    // Public method to request historical data
    func requestHistoricalData() {
        requestHistoricalData(forceFullSync: false)
    }
    
    func requestHistoricalData(forceFullSync: Bool) {
        AppLogger.ble.info("📊 Historical data requested (forceFullSync: \(forceFullSync))")
        resetErrorState()
        historicalDataRequested = true
        
        // Add a flag to force full sync
        if forceFullSync {
            AppLogger.ble.info("🔄 Forcing full historical data sync")
            // Reset lastHistoryIndex for this device to force full sync
            if let deviceUUID = deviceUUID {
                Task {
                    await resetLastHistoryIndex(for: deviceUUID)
                }
            }
        }
        
        // Reset any previous loading state
        loadingStateSubject.send(.idle)
        totalEntries = 0
        currentEntryIndex = 0
        isCancelled = false
        
        AppLogger.ble.info("📊 Connection state - connected: \(self.isConnected), historyControl: \(self.historyControlCharacteristic != nil), historyData: \(self.historyDataCharacteristic != nil), deviceTime: \(self.deviceTimeCharacteristic != nil)")
        
        if isConnected && historyControlCharacteristic != nil && 
           historyDataCharacteristic != nil && deviceTimeCharacteristic != nil {
            AppLogger.ble.info("📊 Starting history data flow immediately")
            startHistoryDataFlow()
        } else if !isConnected {
            AppLogger.ble.info("📊 Not connected, connecting first...")
            // Connect first if not connected
            if let deviceUUID = deviceUUID {
                connectToKnownDevice(deviceUUID: deviceUUID)
            }
        } else {
            AppLogger.ble.bleError("📊 Missing required characteristics for history data")
        }
    }

    // Add complete validation and retry logic
    private func processAndValidateSensorData(_ rawData: Data) {
        guard let deviceUUID = self.deviceUUID else { return }
        
        // Decode the raw data
        if let decodedData = decoder.decodeRealTimeSensorValues(data: rawData, deviceUUID: deviceUUID) {
            Task {
                do {
                    // Validate the sensor data
                    if let validatedData = try await PlantMonitorService.shared.validateSensorData(decodedData, deviceUUID: deviceUUID) {
                        // Reset retry counter on valid data
                        invalidDataRetryCount = 0
                        // Convert to Core Data format for backward compatibility
                        if let coreDataSensorData = validatedData.toCoreDataSensorData() {
                            AppLogger.ble.info("📡 FlowerManager: Live data successfully processed")
                            sensorDataSubject.send(coreDataSensorData)
                            
                            // Mark live data as completed and check if we need to start historical data
                            DispatchQueue.main.async {
                                self.liveDataRequested = false
                                self.onLiveDataCompleted()
                            }
                        } else {
                            AppLogger.ble.bleError("❌ FlowerManager: Failed to convert validated data to Core Data format")
                        }
                    } else {
                        // Data was invalid, retry if we haven't exceeded max attempts
                        handleInvalidData()
                    }
                } catch {
                    print("Error validating sensor data: \(error)")
                    handleInvalidData()
                }
            }
        } else {
            // Decoding failed, retry
            handleInvalidData()
        }
    }
    
    private func handleInvalidData() {
        invalidDataRetryCount += 1
        if (invalidDataRetryCount <= maxRetryAttempts) {
            print("Ungültige Sensordaten. Wiederhole... (Versuch \(invalidDataRetryCount)/\(maxRetryAttempts))")
            // Kurze Verzögerung vor erneutem Versuch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.requestFreshSensorData()
            }
        } else {
            print("Konnte keine gültigen Daten nach \(maxRetryAttempts) Versuchen erhalten")
            invalidDataRetryCount = 0
        }
    }
    
    private func requestFreshSensorData() {
        // Verhindere parallele Anfragen
        guard !isRequestingData else {
            AppLogger.ble.info("🔄 Data request already in progress, skipping...")
            return
        }
        
        guard let peripheral = discoveredPeripheral,
              let modeChar = modeChangeCharacteristic,
              peripheral.state == .connected else {
            AppLogger.ble.bleError("❌ Device not ready for data request - connected: \(discoveredPeripheral?.state.rawValue ?? -1), modeChar: \(modeChangeCharacteristic != nil)")
            return
        }
        
        // Setze das Flag und starte den Timeout-Timer
        isRequestingData = true
        startRequestTimeoutTimer()
        
        AppLogger.ble.bleData("📤 Sending mode change command (0xA01F)")
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.requestFreshSensorData()
                    }
                } else {
                    print("Maximale Anzahl an Versuchen erreicht")
                    self.invalidDataRetryCount = 0
                }
            }
        }
    }
    
    private func decodeHistoryData(data: Data) {
        // Check if operation has been cancelled
        if isCancelled {
            AppLogger.ble.info("❌ History data loading was cancelled")
            return
        }
        
        AppLogger.ble.bleData("📦 Received history data: \(data.count) bytes - Raw: \(data.map { String(format: "%02x", $0) }.joined())")
        
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
                    // Update the last synced index after each successful entry
                    updateLastHistoryIndex(nextIndex)
                    
                    // Add batch processing with longer delays between batches
                    let batchSize = 10
                    if nextIndex % batchSize == 0 {
                        print("Completed batch. Taking a break before next batch...")
                        // Take a longer break between batches to avoid disconnection
                        let batchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] timer in
                            self?.fetchHistoricalDataEntry(index: nextIndex)
                        }
                        self.historyFlowTimers.append(batchTimer)
                    } else {
                        // Increased delay between individual entries
                        let nextEntryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] timer in
                            self?.fetchHistoricalDataEntry(index: nextIndex)
                        }
                        self.historyFlowTimers.append(nextEntryTimer)
                    }
                } else if !isCancelled {
                    // Update the final index
                    updateLastHistoryIndex(totalEntries)
                    AppLogger.ble.info("✅ All historical data fetched successfully - \(self.totalEntries) entries loaded")
                    loadingStateSubject.send(.completed)
                    cleanupHistoryFlow()
                }
            } else {
                AppLogger.ble.bleError("⚠️ Failed to decode history entry \(currentEntryIndex)")
                
                // Error handling when decoding fails
                loadingStateSubject.send(.error("Failed to decode history entry \(currentEntryIndex), trying to skip this"))
                // Try to recover from failed decoding by skipping to the next entry
                let nextIndex = currentEntryIndex + 1
                if (nextIndex < totalEntries) {
                    AppLogger.ble.info("⏭️ Skipping corrupted entry \(self.currentEntryIndex), continuing with next")
                    currentEntryIndex = nextIndex
                    let skipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] timer in
                        self?.fetchHistoricalDataEntry(index: nextIndex)
                    }
                    self.historyFlowTimers.append(skipTimer)
                }
            }
        }
    }
    
    private func fetchHistoricalDataEntry(index: Int) {
        // Check if operation has been cancelled or flow is not active
        if isCancelled || !isHistoryFlowActive {
            AppLogger.ble.info("❌ History data loading was cancelled or flow inactive")
            return
        }
        
        guard let peripheral = discoveredPeripheral,
              peripheral.state == .connected, // Check connection status
              let historyControlCharacteristic = historyControlCharacteristic,
              let historyDataCharacteristic = historyDataCharacteristic else {
            AppLogger.ble.bleError("Cannot fetch history entry: device disconnected or characteristics unavailable")
            cleanupHistoryFlow()
            return
        }
        
        print("Fetching history entry \(index) of \(totalEntries)")
        
        // Format index correctly: 0xa1 + 2-byte index in little endian
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])
        
        // Write address to history control characteristic
        peripheral.writeValue(entryAddress, for: historyControlCharacteristic, type: .withResponse)
        
        // Increased delay to give the device more time to respond
        let readTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] timer in
            guard let self = self,
                  let peripheral = self.discoveredPeripheral,
                  peripheral.state == .connected,
                  self.isHistoryFlowActive && !self.isCancelled else {
                AppLogger.ble.bleError("Device disconnected or flow cancelled before reading data")
                self?.cleanupHistoryFlow()
                return
            }
            
            peripheral.readValue(for: historyDataCharacteristic)
        }
        historyFlowTimers.append(readTimer)
    }
    
    // Connection quality monitoring implementation
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
    
    // MARK: - Nested Types for Compatibility
    enum LoadingState: Equatable {
        case idle
        case loading  
        case completed
        case error(String)
    }

    enum ConnectionState {
        case disconnected
        case connecting  
        case connected
        case authenticating
        case ready
        case error(BLEError)
        
        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .authenticating: return "Authenticating"
            case .ready: return "Ready"
            case .error(let error): return "Error: \(error.localizedDescription)"
            }
        }
    }

    enum ConnectionQuality {
        case unknown
        case poor
        case fair
        case good
        
        var description: String {
            switch self {
            case .unknown: return "unknown"
            case .poor: return "poor"
            case .fair: return "fair" 
            case .good: return "good"
            }
        }
    }
    
    enum BLEError: Error, Equatable {
        case deviceNotFound
        case connectionFailed
        case authenticationFailed
        case characteristicNotFound
        case dataDecodingFailed
        case deviceDisconnected
        case timeout
        case invalidResponse
        case insufficientDataLength
        
        var localizedDescription: String {
            switch self {
            case .deviceNotFound: return "Device not found"
            case .connectionFailed: return "Connection failed"
            case .authenticationFailed: return "Authentication failed"
            case .characteristicNotFound: return "Required characteristic not found"
            case .dataDecodingFailed: return "Failed to decode sensor data"
            case .deviceDisconnected: return "Device disconnected unexpectedly"
            case .timeout: return "Operation timed out"
            case .invalidResponse: return "Invalid response from device"
            case .insufficientDataLength: return "Insufficient data received"
            }
        }
        
        var isRecoverable: Bool {
            switch self {
            case .deviceDisconnected, .timeout, .connectionFailed:
                return true
            case .authenticationFailed, .characteristicNotFound:
                return false
            case .dataDecodingFailed, .invalidResponse, .insufficientDataLength:
                return true
            case .deviceNotFound:
                return true
            }
        }
    }
    
}
