//
//  ReliableFlowerManager.swift
//  GrowGuard
//
//  Boring but reliable BLE implementation
//
//  Key Design Principles:
//  1. SEQUENTIAL OPERATIONS - Only one operation at a time, period
//  2. PESSIMISTIC TIMING - Conservative delays, no adaptive algorithms  
//  3. SIMPLE STATE MACHINE - Clear states with explicit transitions
//  4. TRANSPARENT PROGRESS - User always knows what's happening
//  5. ROBUST RECOVERY - Expect failures, retry with backoff
//  6. PREDICTABLE BEHAVIOR - Same timing every time, no surprises
//
//  Conservative Timing (all delays in seconds):
//  - Connection timeout: 10.0s  
//  - Characteristic discovery: 2.0s
//  - Data read: 1.5s
//  - Data write: 1.0s  
//  - Batch pause: 5.0s
//  - Max 10 entries per batch
//  - Major pause every 50 entries
//

import Foundation
import CoreBluetooth
import Combine

// MARK: - Simple State Machine

enum BLEConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case authenticating
    case ready
    case operating
    case failed(String)
}

enum BLEOperation: Equatable {
    case connect
    case authenticate
    case readLiveData
    case readHistoryCount
    case readHistoryEntry(index: Int)
    case disconnect
    
    var maxRetries: Int {
        switch self {
        case .connect: return 3
        case .authenticate: return 2
        case .readLiveData: return 3
        case .readHistoryCount: return 3
        case .readHistoryEntry: return 2
        case .disconnect: return 1
        }
    }
    
    var timeout: TimeInterval {
        switch self {
        case .connect: return 10.0
        case .authenticate: return 5.0
        case .readLiveData: return 3.0
        case .readHistoryCount: return 5.0
        case .readHistoryEntry: return 1.5
        case .disconnect: return 5.0
        }
    }
}

enum BLEStatus {
    case idle
    case connecting
    case authenticating
    case readingCount
    case readingEntry(current: Int, total: Int)
    case pausing(reason: String, seconds: Int)
    case retrying(operation: String, attempt: Int, of: Int)
    case completed
    case failed(String)
}

// MARK: - Reliable BLE Manager

class ReliableFlowerManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // MARK: - Core Properties
    private var centralManager: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?
    private var deviceUUID: String?
    
    // MARK: - Characteristics
    private var modeChangeCharacteristic: CBCharacteristic?
    private var realTimeSensorValuesCharacteristic: CBCharacteristic?
    private var historyControlCharacteristic: CBCharacteristic?
    private var historyDataCharacteristic: CBCharacteristic?
    private var deviceTimeCharacteristic: CBCharacteristic?
    
    // MARK: - State Management
    private var connectionState: BLEConnectionState = .disconnected
    private var currentOperation: BLEOperation?
    private var operationQueue: [BLEOperation] = []
    private var operationRetryCount = 0
    private var operationTimer: Timer?
    private var characteristicCheckTimer: Timer?
    private var discoveredServices = 0
    private var totalServices = 0
    
    // MARK: - Data Properties
    private var totalHistoryEntries = 0
    private var currentHistoryIndex = 0
    private let decoder = SensorDataDecoder()
    private let repositoryManager = RepositoryManager.shared

    // MARK: - Request Flags
    private var pendingHistoryRequest = false
    private var pendingLiveDataRequest = false

    // MARK: - Publishers
    private let sensorDataSubject = PassthroughSubject<SensorData, Never>()
    private let historicalDataSubject = PassthroughSubject<HistoricalSensorData, Never>()
    private let deviceUpdateSubject = PassthroughSubject<FlowerDeviceDTO, Never>()
    private let statusSubject = CurrentValueSubject<BLEStatus, Never>(.idle)
    private let connectionStateSubject = CurrentValueSubject<BLEConnectionState, Never>(.disconnected)
    private let connectionQualitySubject = CurrentValueSubject<ConnectionQuality, Never>(.unknown)
    private let loadingProgressSubject = CurrentValueSubject<(current: Int, total: Int), Never>((0, 0))

    var sensorDataPublisher: AnyPublisher<SensorData, Never> {
        sensorDataSubject.eraseToAnyPublisher()
    }

    var historicalDataPublisher: AnyPublisher<HistoricalSensorData, Never> {
        historicalDataSubject.eraseToAnyPublisher()
    }

    var deviceUpdatePublisher: AnyPublisher<FlowerDeviceDTO, Never> {
        deviceUpdateSubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<BLEStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<BLEConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    var rssiDistancePublisher: AnyPublisher<String, Never> {
        connectionQualitySubject
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
    
    // MARK: - Constants - Optimized for Performance
    private let connectTimeout: TimeInterval = 10.0
    private let characteristicDiscoveryDelay: TimeInterval = 2.0
    private let dataReadDelay: TimeInterval = 0.2
    private let dataWriteDelay: TimeInterval = 0.15
    private let batchPauseDelay: TimeInterval = 0.5
    private let maxEntriesPerBatch = 30
    private let totalPauseEveryNEntries = 0  // Disabled for better performance
    
    // MARK: - UUIDs (use external definitions for consistency)
    
    static let shared = ReliableFlowerManager()
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        log("ReliableFlowerManager initialized")
    }
    
    // MARK: - Logging
    private func log(_ message: String) {
        print("[ReliableBLE] \(message)")
    }
    
    // MARK: - Public Interface
    
    func connectToDevice(_ deviceUUID: String) {
        log("Requested connection to device: \(deviceUUID)")
        self.deviceUUID = deviceUUID

        // If we're not disconnected, disconnect first
        if connectionState != .disconnected {
            log("Not disconnected (state: \(connectionState)), disconnecting first...")
            // Cleanup current state
            if let peripheral = discoveredPeripheral {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            clearOperationQueue()
            updateConnectionState(.disconnected)
        }

        clearOperationQueue()
        operationQueue = [.connect, .authenticate]
        processNextOperation()
    }
    
    func requestLiveData() {
        log("Requested live data (current state: \(connectionState))")
        pendingLiveDataRequest = true

        if connectionState == .ready {
            log("Device ready - adding live data operation to queue")
            addOperation(.readLiveData)
            pendingLiveDataRequest = false
        } else {
            log("Device not ready - will request live data when ready")
        }
    }
    
    func requestHistoricalData() {
        log("Requested historical data (current state: \(connectionState))")
        pendingHistoryRequest = true

        // Reset counters
        totalHistoryEntries = 0
        currentHistoryIndex = 0

        if connectionState == .ready {
            log("Device ready - adding history operation to queue")
            addOperation(.readHistoryCount)
            pendingHistoryRequest = false
        } else {
            log("Device not ready - will request historical data when ready")
        }
    }

    func disconnect() {
        log("Requested disconnect")
        addOperation(.disconnect)
    }
    
    // MARK: - Operation Management
    
    private func addOperation(_ operation: BLEOperation) {
        log("Adding operation to queue: \(operation)")
        operationQueue.append(operation)
        if currentOperation == nil {
            processNextOperation()
        } else {
            log("Operation queued, will execute after current operation completes")
        }
    }
    
    private func processNextOperation() {
        guard currentOperation == nil else {
            log("Operation already in progress: \(String(describing: currentOperation))")
            return
        }
        
        guard let operation = operationQueue.first else {
            log("No operations in queue")
            if connectionState == .ready {
                updateStatus(.idle)
            }
            return
        }
        
        operationQueue.removeFirst()
        currentOperation = operation
        operationRetryCount = 0
        
        log("Starting operation: \(operation)")
        executeOperation(operation)
    }
    
    private func executeOperation(_ operation: BLEOperation) {
        // Start timeout timer
        startOperationTimeout(operation)
        
        switch operation {
        case .connect:
            executeConnect()
        case .authenticate:
            executeAuthenticate()
        case .readLiveData:
            executeReadLiveData()
        case .readHistoryCount:
            executeReadHistoryCount()
        case .readHistoryEntry(let index):
            executeReadHistoryEntry(index)
        case .disconnect:
            executeDisconnect()
        }
    }
    
    private func startOperationTimeout(_ operation: BLEOperation) {
        operationTimer?.invalidate()
        operationTimer = Timer.scheduledTimer(withTimeInterval: operation.timeout, repeats: false) { [weak self] _ in
            self?.handleOperationTimeout(operation)
        }
    }
    
    private func handleOperationTimeout(_ operation: BLEOperation) {
        log("Operation timeout: \(operation)")
        completeOperation(success: false, error: "Operation timeout")
    }
    
    private func completeOperation(success: Bool, error: String? = nil) {
        operationTimer?.invalidate()
        operationTimer = nil
        
        let operation = currentOperation
        currentOperation = nil
        
        guard let op = operation else { return }
        
        if success {
            log("Operation completed successfully: \(op)")
            handleOperationSuccess(op)
        } else {
            log("Operation failed: \(op), error: \(error ?? "unknown")")
            handleOperationFailure(op, error: error ?? "unknown")
        }
    }
    
    private func handleOperationSuccess(_ operation: BLEOperation) {
        switch operation {
        case .connect:
            updateConnectionState(.connected)
            
        case .authenticate:
            updateConnectionState(.ready)
            updateStatus(.idle)

            // Process any pending requests
            if pendingLiveDataRequest {
                log("Processing pending live data request")
                pendingLiveDataRequest = false
                addOperation(.readLiveData)
            }

            if pendingHistoryRequest {
                log("Processing pending history request")
                pendingHistoryRequest = false
                addOperation(.readHistoryCount)
            }
            
        case .readLiveData:
            // Live data handling completed in delegate
            break
            
        case .readHistoryCount:
            if totalHistoryEntries > 0 {
                log("Will read \(totalHistoryEntries) history entries")
                loadingProgressSubject.send((0, totalHistoryEntries))
                // Queue up all history entries
                for i in 0..<totalHistoryEntries {
                    addOperation(.readHistoryEntry(index: i))
                }
            } else {
                updateStatus(.completed)
            }
            
        case .readHistoryEntry(let index):
            let nextIndex = index + 1
            updateStatus(.readingEntry(current: nextIndex, total: totalHistoryEntries))
            loadingProgressSubject.send((nextIndex, totalHistoryEntries))

            // Add pause every batch
            if nextIndex % maxEntriesPerBatch == 0 && nextIndex < totalHistoryEntries {
                log("Pausing after batch of \(maxEntriesPerBatch) entries")
                pauseOperations(seconds: Int(batchPauseDelay), reason: "batch break")
            }

            // Major pauses disabled for better performance (totalPauseEveryNEntries = 0)

            if nextIndex >= totalHistoryEntries {
                updateStatus(.completed)
                log("All history entries completed")
            }
            
        case .disconnect:
            updateConnectionState(.disconnected)
            updateStatus(.idle)
            // Reset pending requests
            pendingLiveDataRequest = false
            pendingHistoryRequest = false
        }
        
        // Process next operation
        processNextOperation()
    }
    
    private func handleOperationFailure(_ operation: BLEOperation, error: String) {
        operationRetryCount += 1
        
        if operationRetryCount <= operation.maxRetries {
            log("Retrying operation \(operation): attempt \(operationRetryCount)/\(operation.maxRetries)")
            updateStatus(.retrying(operation: "\(operation)", attempt: operationRetryCount, of: operation.maxRetries))
            
            // Wait before retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.executeOperation(operation)
            }
        } else {
            log("Operation \(operation) failed after \(operation.maxRetries) attempts")
            updateConnectionState(.failed(error))
            updateStatus(.failed("Operation failed: \(error)"))
            clearOperationQueue()
        }
    }
    
    private func pauseOperations(seconds: Int, reason: String) {
        updateStatus(.pausing(reason: reason, seconds: seconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(seconds)) {
            self.processNextOperation()
        }
    }
    
    private func clearOperationQueue() {
        operationQueue.removeAll()
        currentOperation = nil
        operationTimer?.invalidate()
        operationTimer = nil
        characteristicCheckTimer?.invalidate()
        characteristicCheckTimer = nil
    }
    
    // MARK: - State Updates
    
    private func updateConnectionState(_ newState: BLEConnectionState) {
        log("Connection state: \(connectionState) → \(newState)")
        connectionState = newState
        connectionStateSubject.send(newState)
    }
    
    private func updateStatus(_ newStatus: BLEStatus) {
        log("Status: \(newStatus)")
        statusSubject.send(newStatus)
    }
    
    // MARK: - Operation Implementations
    
    private func executeConnect() {
        updateStatus(.connecting)
        updateConnectionState(.connecting)
        
        guard let deviceUUID = deviceUUID,
              let uuid = UUID(uuidString: deviceUUID) else {
            completeOperation(success: false, error: "Invalid device UUID")
            return
        }
        
        // Try to retrieve known peripheral first
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            log("Found known peripheral, connecting directly")
            discoveredPeripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        } else {
            log("Peripheral not known, starting scan")
            if centralManager.state == .poweredOn {
                centralManager.scanForPeripherals(withServices: [flowerCareServiceUUID], options: nil)
            } else {
                completeOperation(success: false, error: "Bluetooth not powered on")
            }
        }
    }
    
    private func executeAuthenticate() {
        updateStatus(.authenticating)
        updateConnectionState(.authenticating)
        
        guard let peripheral = discoveredPeripheral,
              peripheral.state == .connected else {
            completeOperation(success: false, error: "Device not connected")
            return
        }
        
        log("Starting service discovery")
        peripheral.discoverServices(nil)
    }
    
    private func executeReadLiveData() {
        guard let peripheral = discoveredPeripheral,
              let modeChar = modeChangeCharacteristic,
              let sensorChar = realTimeSensorValuesCharacteristic,
              peripheral.state == .connected else {
            completeOperation(success: false, error: "Device not ready for live data")
            return
        }

        log("Writing mode change command for live data")
        let command: [UInt8] = [0xA0, 0x1F]
        peripheral.writeValue(Data(command), for: modeChar, type: .withResponse)

        // After writing, wait a bit and then read the sensor values
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self,
                  let peripheral = self.discoveredPeripheral,
                  peripheral.state == .connected else {
                self?.log("Device disconnected before reading sensor data")
                self?.completeOperation(success: false, error: "Device disconnected")
                return
            }

            self.log("Reading sensor values characteristic")
            peripheral.readValue(for: sensorChar)
        }
    }
    
    private func executeReadHistoryCount() {
        updateStatus(.readingCount)
        
        guard let peripheral = discoveredPeripheral,
              let historyControl = historyControlCharacteristic,
              peripheral.state == .connected else {
            completeOperation(success: false, error: "Device not ready for history")
            return
        }
        
        log("Setting up history mode")
        // Step 1: Set history mode
        let modeCommand: [UInt8] = [0xa0, 0x00, 0x00]
        peripheral.writeValue(Data(modeCommand), for: historyControl, type: .withResponse)
        
        // Step 2: Read device time (after delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + dataWriteDelay) {
            if let deviceTimeChar = self.deviceTimeCharacteristic {
                peripheral.readValue(for: deviceTimeChar)
            }
            
            // Step 3: Get entry count (after delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + self.dataReadDelay) {
                let entryCountCommand: [UInt8] = [0x3c]
                peripheral.writeValue(Data(entryCountCommand), for: historyControl, type: .withResponse)
                
                // Step 4: Read the response (after delay)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.dataWriteDelay) {
                    if let historyData = self.historyDataCharacteristic {
                        peripheral.readValue(for: historyData)
                    }
                }
            }
        }
    }
    
    private func executeReadHistoryEntry(_ index: Int) {
        guard let peripheral = discoveredPeripheral,
              let historyControl = historyControlCharacteristic,
              let historyData = historyDataCharacteristic,
              peripheral.state == .connected else {
            completeOperation(success: false, error: "Device not ready for history entry")
            return
        }
        
        log("Reading history entry \(index)")
        
        // Format index: 0xa1 + 2-byte index in little endian
        let entryAddress = Data([0xa1, UInt8(index & 0xff), UInt8((index >> 8) & 0xff)])
        peripheral.writeValue(entryAddress, for: historyControl, type: .withResponse)
        
        // Read after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + dataWriteDelay) {
            peripheral.readValue(for: historyData)
        }
    }
    
    private func executeDisconnect() {
        guard let peripheral = discoveredPeripheral else {
            completeOperation(success: true)
            return
        }
        
        log("Disconnecting from peripheral")
        centralManager.cancelPeripheralConnection(peripheral)
        
        // Clean up
        discoveredPeripheral = nil
        modeChangeCharacteristic = nil
        realTimeSensorValuesCharacteristic = nil
        historyControlCharacteristic = nil
        historyDataCharacteristic = nil
        deviceTimeCharacteristic = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension ReliableFlowerManager {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central manager state: \(central.state.rawValue)")
        
        if central.state != .poweredOn {
            updateConnectionState(.failed("Bluetooth not available"))
            updateStatus(.failed("Bluetooth not available"))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier.uuidString == deviceUUID else { return }
        
        log("Discovered target peripheral, connecting...")
        centralManager.stopScan()
        discoveredPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to peripheral")
        
        // Connection success - complete the connect operation
        if currentOperation == .connect {
            completeOperation(success: true)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected from peripheral. Error: \(error?.localizedDescription ?? "none")")
        
        // Clean up connection state
        updateConnectionState(.disconnected)
        
        if currentOperation == .disconnect {
            completeOperation(success: true)
        } else {
            // Unexpected disconnection
            updateStatus(.failed("Unexpected disconnection"))
            clearOperationQueue()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect to peripheral: \(error?.localizedDescription ?? "unknown")")
        
        if currentOperation == .connect {
            completeOperation(success: false, error: error?.localizedDescription ?? "Connection failed")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ReliableFlowerManager {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Service discovery failed: \(error.localizedDescription)")
            if currentOperation == .authenticate {
                completeOperation(success: false, error: error.localizedDescription)
            }
            return
        }

        log("Services discovered, discovering characteristics...")

        guard let services = peripheral.services else {
            if currentOperation == .authenticate {
                completeOperation(success: false, error: "No services found")
            }
            return
        }

        totalServices = services.count
        discoveredServices = 0
        log("Will discover characteristics for \(totalServices) services")

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Characteristic discovery failed: \(error.localizedDescription)")
            if currentOperation == .authenticate {
                completeOperation(success: false, error: error.localizedDescription)
            }
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        log("Discovered \(characteristics.count) characteristics")
        
        for characteristic in characteristics {
            switch characteristic.uuid {
            case deviceModeChangeCharacteristicUUID:
                modeChangeCharacteristic = characteristic
                log("Found mode change characteristic")
            case realTimeSensorValuesCharacteristicUUID:
                realTimeSensorValuesCharacteristic = characteristic
                log("Found real-time sensor characteristic")
            case historyControlCharacteristicUUID:
                historyControlCharacteristic = characteristic
                log("Found history control characteristic")
            case historicalSensorValuesCharacteristicUUID:
                historyDataCharacteristic = characteristic
                log("Found history data characteristic")
            case deviceTimeCharacteristicUUID:
                deviceTimeCharacteristic = characteristic
                log("Found device time characteristic")
            case firmwareVersionCharacteristicUUID:
                log("Found firmware version characteristic")
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }

        // Increment discovered services counter
        discoveredServices += 1
        log("Discovered characteristics for service \(discoveredServices)/\(totalServices)")

        // Check if we have all required characteristics only after all services are discovered
        if currentOperation == .authenticate && discoveredServices >= totalServices {
            // Cancel any existing timer
            characteristicCheckTimer?.invalidate()

            // Wait a bit to make sure all characteristics are processed
            characteristicCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }

                let hasRequired = self.modeChangeCharacteristic != nil &&
                                 self.realTimeSensorValuesCharacteristic != nil &&
                                 self.historyControlCharacteristic != nil &&
                                 self.historyDataCharacteristic != nil &&
                                 self.deviceTimeCharacteristic != nil

                if hasRequired {
                    self.log("All required characteristics found")
                    // Wait a bit for characteristic setup to settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.characteristicDiscoveryDelay) {
                        self.completeOperation(success: true)
                    }
                } else {
                    self.log("Missing required characteristics after all services discovered")
                    self.log("  modeChange: \(self.modeChangeCharacteristic != nil)")
                    self.log("  realTime: \(self.realTimeSensorValuesCharacteristic != nil)")
                    self.log("  historyControl: \(self.historyControlCharacteristic != nil)")
                    self.log("  historyData: \(self.historyDataCharacteristic != nil)")
                    self.log("  deviceTime: \(self.deviceTimeCharacteristic != nil)")
                    self.completeOperation(success: false, error: "Missing required characteristics")
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Failed to read characteristic \(characteristic.uuid): \(error.localizedDescription)")
            if currentOperation != nil {
                completeOperation(success: false, error: error.localizedDescription)
            }
            return
        }
        
        guard let data = characteristic.value else {
            log("No data received for characteristic \(characteristic.uuid)")
            return
        }
        
        switch characteristic.uuid {
        case realTimeSensorValuesCharacteristicUUID:
            handleRealTimeSensorData(data)

        case historicalSensorValuesCharacteristicUUID:
            handleHistoryData(data)

        case deviceTimeCharacteristicUUID:
            log("Device time read successfully")
            // Device time read is part of history setup, no completion needed

        case firmwareVersionCharacteristicUUID:
            handleFirmwareAndBattery(data)

        default:
            log("Received data for unhandled characteristic: \(characteristic.uuid)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Failed to write to characteristic \(characteristic.uuid): \(error.localizedDescription)")
            if currentOperation != nil {
                completeOperation(success: false, error: error.localizedDescription)
            }
        } else {
            log("Successfully wrote to characteristic \(characteristic.uuid)")
        }
    }
}

// MARK: - Data Handling

extension ReliableFlowerManager {
    
    private func handleRealTimeSensorData(_ data: Data) {
        log("Processing real-time sensor data")
        
        guard let deviceUUID = self.deviceUUID else {
            log("No device UUID for sensor data")
            return
        }
        
        if let sensorData = decoder.decodeRealTimeSensorValues(data: data, deviceUUID: deviceUUID) {
            Task {
                do {
                    if let validatedData = try await PlantMonitorService.shared.validateSensorData(sensorData, deviceUUID: deviceUUID) {
                        if let coreDataSensorData = validatedData.toCoreDataSensorData() {
                            await MainActor.run {
                                self.sensorDataSubject.send(coreDataSensorData)
                            }
                        }
                    }
                } catch {
                    self.log("Error validating sensor data: \(error)")
                }
            }
        }
        
        // Complete live data operation
        if currentOperation == .readLiveData {
            completeOperation(success: true)
        }
    }
    
    private func handleHistoryData(_ data: Data) {
        log("Processing history data (\(data.count) bytes)")
        
        // Check if this is entry count response
        if currentOperation == .readHistoryCount {
            if let count = decoder.decodeEntryCount(data: data) {
                totalHistoryEntries = count
                log("History entry count: \(count)")
                completeOperation(success: true)
            } else if let (count, _) = decoder.decodeHistoryMetadata(data: data) {
                totalHistoryEntries = count
                log("History entry count from metadata: \(count)")
                completeOperation(success: true)
            } else {
                log("Failed to decode history count")
                completeOperation(success: false, error: "Failed to decode history count")
            }
            return
        }
        
        // Check if this is a history entry
        if case .readHistoryEntry(let index) = currentOperation {
            if let historicalData = decoder.decodeHistoricalSensorData(data: data) {
                log("Decoded history entry \(index): temp=\(historicalData.temperature)°C")
                
                // Publish historical data
                Task {
                    await MainActor.run {
                        self.historicalDataSubject.send(historicalData)
                    }
                }
                
                completeOperation(success: true)
            } else {
                log("Failed to decode history entry \(index)")
                completeOperation(success: false, error: "Failed to decode history entry")
            }
        }
    }

    // MARK: - Additional Features

    func connectToKnownDevice(deviceUUID: String) {
        log("Connect to known device requested: \(deviceUUID)")
        connectToDevice(deviceUUID)
    }

    private func handleFirmwareAndBattery(_ data: Data) {
        guard let (battery, firmware) = decoder.decodeFirmwareAndBattery(data: data) else {
            log("Failed to decode firmware and battery")
            return
        }

        log("Battery: \(battery)%, Firmware: \(firmware)")

        guard let deviceUUID = self.deviceUUID else { return }

        Task {
            do {
                guard var deviceDTO = try await repositoryManager.flowerDeviceRepository.getDevice(by: deviceUUID) else {
                    self.log("Device not found for UUID: \(deviceUUID)")
                    return
                }

                // Update battery level and firmware
                deviceDTO = FlowerDeviceDTO(
                    id: deviceDTO.id,
                    name: deviceDTO.name,
                    uuid: deviceDTO.uuid,
                    peripheralID: deviceDTO.peripheralID,
                    battery: Int16(battery),
                    firmware: firmware,
                    isSensor: deviceDTO.isSensor,
                    added: deviceDTO.added,
                    lastUpdate: deviceDTO.lastUpdate,
                    optimalRange: deviceDTO.optimalRange,
                    potSize: deviceDTO.potSize,
                    selectedFlower: deviceDTO.selectedFlower,
                    sensorData: deviceDTO.sensorData
                )

                try await repositoryManager.flowerDeviceRepository.updateDevice(deviceDTO)
                self.log("Successfully updated battery and firmware for device \(deviceUUID)")

                // Publish the updated device
                await MainActor.run {
                    self.deviceUpdateSubject.send(deviceDTO)
                }
            } catch {
                self.log("Error updating device battery/firmware: \(error)")
            }
        }
    }

    func blinkLED() {
        guard let peripheral = discoveredPeripheral,
              peripheral.state == .connected,
              let ledChar = modeChangeCharacteristic else {
            log("Cannot blink LED: device not ready")
            return
        }

        log("Blinking LED")
        let blinkData = Data([0xfd, 0xff])
        peripheral.writeValue(blinkData, for: ledChar, type: .withResponse)
    }

    // MARK: - Connection Quality

    enum ConnectionQuality {
        case unknown
        case poor
        case fair
        case good
    }

    enum LoadingState: Equatable {
        case idle
        case loading
        case completed
        case error(String)
    }

    var currentDeviceUUID: String? {
        return deviceUUID
    }

    var loadingProgressPublisher: AnyPublisher<(current: Int, total: Int), Never> {
        loadingProgressSubject.eraseToAnyPublisher()
    }

    var loadingStatePublisher: AnyPublisher<LoadingState, Never> {
        statusPublisher
            .map { status in
                switch status {
                case .idle: return .idle
                case .connecting, .authenticating, .readingCount, .readingEntry, .pausing, .retrying: return .loading
                case .completed: return .completed
                case .failed(let error): return .error(error)
                }
            }
            .eraseToAnyPublisher()
    }

    var connectionQualityPublisher: AnyPublisher<ConnectionQuality, Never> {
        connectionQualitySubject.eraseToAnyPublisher()
    }

    func cancelHistoryDataLoading() {
        log("Cancelling history data loading")
        clearOperationQueue()
        updateStatus(.idle)
        disconnect()
    }

    func forceResetHistoryState() {
        log("Force resetting history state")
        clearOperationQueue()
        totalHistoryEntries = 0
        currentHistoryIndex = 0
        updateStatus(.idle)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            log("Failed to read RSSI: \(error.localizedDescription)")
            connectionQualitySubject.send(.unknown)
            return
        }

        let rssiValue = RSSI.intValue
        let quality: ConnectionQuality

        if rssiValue >= -65 {
            quality = .good
        } else if rssiValue >= -80 {
            quality = .fair
        } else {
            quality = .poor
        }

        log("RSSI: \(rssiValue) dBm - Quality: \(quality)")
        connectionQualitySubject.send(quality)
    }
}