# Disconnect Loop Prevention Solution

## Problem Analysis

The current `didDisconnectPeripheral` method in FlowerManager.swift causes disconnect loops because:

1. **Immediate Reconnection**: Reconnects within 2-3 seconds without analyzing why the disconnect occurred
2. **No State Persistence**: Loses progress context when disconnecting, leading to restarts
3. **No Disconnect Pattern Analysis**: Doesn't distinguish between intentional disconnects and connection issues
4. **Cleanup Race Conditions**: `cleanupHistoryFlow()` resets state before reconnection logic can use it

## Current Problematic Flow

```swift
func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    // ❌ PROBLEM: Immediate cleanup loses state
    cleanupHistoryFlow()  
    
    // ❌ PROBLEM: Simple condition check without loop prevention
    if historicalDataRequested && totalEntries > 0 && currentEntryIndex < totalEntries && !isCancelled {
        // ❌ PROBLEM: Immediate reconnection without backoff
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.connectToKnownDevice(deviceUUID: deviceUUID) // Can loop infinitely
        }
    }
}
```

## Comprehensive Solution

### 1. Persistent History Session State

```swift
// Add to FlowerCareManager class
private struct HistorySessionState {
    let deviceUUID: String
    let totalEntries: Int
    let currentIndex: Int
    let startTime: Date
    let lastSuccessfulIndex: Int
    let sessionID: UUID
    var disconnectCount: Int = 0
    var consecutiveFailures: Int = 0
    
    var isComplete: Bool {
        return currentIndex >= totalEntries
    }
    
    var progressPercentage: Double {
        guard totalEntries > 0 else { return 0 }
        return Double(currentIndex) / Double(totalEntries)
    }
}

private var currentHistorySession: HistorySessionState?
```

### 2. Intelligent Disconnect Handler

```swift
// Enhanced disconnect detection and handling
func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    AppLogger.ble.bleConnection("Disconnected from peripheral: \(peripheral.identifier)")
    
    // Update connection state
    connectionStateSubject.send(.disconnected)
    isConnected = false
    
    // Analyze disconnect reason and context
    let disconnectContext = analyzeDisconnectContext(error: error)
    
    // Handle based on disconnect type and current session state
    handleDisconnectWithContext(disconnectContext, peripheral: peripheral)
}

private func analyzeDisconnectContext(error: Error?) -> DisconnectContext {
    var reason: DisconnectReason = .unknown
    var isRecoverable = true
    
    if let error = error {
        let nsError = error as NSError
        switch nsError.code {
        case 6: // CBError.connectionTimeout
            reason = .timeout
        case 7: // CBError.peripheralDisconnected  
            reason = .deviceInitiated
        case 10: // CBError.connectionFailed
            reason = .connectionLost
            isRecoverable = false
        default:
            reason = .systemError
            AppLogger.ble.bleError("Disconnect error: \(error.localizedDescription)")
        }
    } else {
        reason = .userInitiated // No error means intentional disconnect
        isRecoverable = false
    }
    
    return DisconnectContext(
        reason: reason,
        isRecoverable: isRecoverable,
        hasActiveSession: currentHistorySession != nil,
        sessionProgress: currentHistorySession?.progressPercentage ?? 0.0
    )
}

private enum DisconnectReason {
    case timeout
    case deviceInitiated  
    case connectionLost
    case systemError
    case userInitiated
    case unknown
}

private struct DisconnectContext {
    let reason: DisconnectReason
    let isRecoverable: Bool
    let hasActiveSession: Bool
    let sessionProgress: Double
}
```

### 3. Smart Reconnection Strategy

```swift
private func handleDisconnectWithContext(_ context: DisconnectContext, peripheral: CBPeripheral) {
    // Don't attempt recovery for intentional disconnects
    guard context.isRecoverable else {
        AppLogger.ble.info("🚫 Not attempting recovery - disconnect was intentional")
        finalizeDisconnect()
        return
    }
    
    // Check if we have an active history session to resume
    guard let session = currentHistorySession else {
        AppLogger.ble.info("📊 No active history session - standard disconnect handling")
        finalizeDisconnect()
        return
    }
    
    // Update session with disconnect info
    currentHistorySession?.disconnectCount += 1
    
    // Check for disconnect loop patterns
    if shouldAttemptReconnection(session: session, context: context) {
        attemptIntelligentReconnection(session: session, context: context)
    } else {
        AppLogger.ble.bleError("🔄 Too many disconnects - aborting session")
        abortHistorySession(reason: "Excessive disconnections")
    }
}

private func shouldAttemptReconnection(session: HistorySessionState, context: DisconnectContext) -> Bool {
    // Don't reconnect if cancelled
    if isCancelled {
        return false
    }
    
    // Check disconnect frequency (max 5 disconnects per session)
    if session.disconnectCount >= 5 {
        AppLogger.ble.bleError("🚫 Too many disconnects in session (\(session.disconnectCount))")
        return false
    }
    
    // Check if we're making progress (at least 5% between disconnects)
    let progressSinceLastDisconnect = session.currentIndex - session.lastSuccessfulIndex
    if session.disconnectCount > 2 && progressSinceLastDisconnect < max(5, session.totalEntries / 20) {
        AppLogger.ble.bleError("🚫 Insufficient progress between disconnects")
        return false
    }
    
    // Check session duration (max 30 minutes)
    let sessionDuration = Date().timeIntervalSince(session.startTime)
    if sessionDuration > 1800 { // 30 minutes
        AppLogger.ble.bleError("🚫 Session timeout - too long duration")
        return false
    }
    
    // Check for rapid disconnect patterns (more than 3 in 2 minutes)
    let recentDisconnects = disconnectHistory.filter { 
        Date().timeIntervalSince($0) < 120 
    }.count
    
    if recentDisconnects >= 3 {
        AppLogger.ble.bleError("🚫 Rapid disconnect pattern detected")
        return false
    }
    
    return true
}

// Track recent disconnects for pattern analysis
private var disconnectHistory: [Date] = []

private func attemptIntelligentReconnection(session: HistorySessionState, context: DisconnectContext) {
    // Record disconnect time
    disconnectHistory.append(Date())
    
    // Clean up old disconnect history (keep last 10)
    if disconnectHistory.count > 10 {
        disconnectHistory.removeFirst()
    }
    
    // Calculate smart delay based on disconnect pattern
    let reconnectDelay = calculateReconnectDelay(
        disconnectCount: session.disconnectCount,
        context: context
    )
    
    AppLogger.ble.info("🔄 Scheduling intelligent reconnection in \(reconnectDelay)s (disconnect #\(session.disconnectCount))")
    
    // Update UI to show reconnection attempt
    loadingStateSubject.send(.loading)
    
    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
        guard let self = self else { return }
        
        // Double-check we still should reconnect
        guard let currentSession = self.currentHistorySession,
              !self.isCancelled,
              currentSession.sessionID == session.sessionID else {
            AppLogger.ble.info("📊 Session changed or cancelled - aborting reconnection")
            return
        }
        
        AppLogger.ble.info("🔄 Attempting intelligent reconnection for session \(session.sessionID)")
        self.reconnectAndResumeSession(session: currentSession)
    }
}

private func calculateReconnectDelay(disconnectCount: Int, context: DisconnectContext) -> TimeInterval {
    // Base delay depends on disconnect reason
    var baseDelay: TimeInterval = 2.0
    
    switch context.reason {
    case .timeout:
        baseDelay = 3.0 // Device might need more time
    case .deviceInitiated:
        baseDelay = 1.5 // Device probably ready quickly
    case .connectionLost:
        baseDelay = 5.0 // Connection issues need more time
    case .systemError:
        baseDelay = 4.0 // System issues need settling time
    default:
        baseDelay = 2.0
    }
    
    // Exponential backoff for repeated disconnects
    let backoffMultiplier = min(pow(1.5, Double(disconnectCount - 1)), 8.0) // Max 8x
    let finalDelay = baseDelay * backoffMultiplier
    
    // Cap maximum delay at 30 seconds
    return min(finalDelay, 30.0)
}
```

### 4. Seamless Session Resumption

```swift
private func reconnectAndResumeSession(session: HistorySessionState) {
    guard let deviceUUID = session.deviceUUID else {
        abortHistorySession(reason: "No device UUID")
        return
    }
    
    AppLogger.ble.info("🔄 Reconnecting to resume session at index \(session.currentIndex)/\(session.totalEntries)")
    
    // Connect with specific resume context
    connectionAttemptContext = .resumeHistorySession(sessionID: session.sessionID)
    connectToKnownDevice(deviceUUID: deviceUUID)
}

private enum ConnectionAttemptContext {
    case newSession
    case resumeHistorySession(sessionID: UUID)
    case liveDataOnly
}

private var connectionAttemptContext: ConnectionAttemptContext = .newSession

// Modified connection success handler
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    AppLogger.ble.bleConnection("Connected to: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
    connectionStateSubject.send(.connected)
    peripheral.delegate = self
    peripheral.discoverServices(nil)
    
    // Handle based on connection context
    switch connectionAttemptContext {
    case .resumeHistorySession(let sessionID):
        handleSessionResumption(sessionID: sessionID)
    case .newSession:
        // Normal flow - will be handled in didDiscoverCharacteristics
        break
    case .liveDataOnly:
        // Only live data requested
        break
    }
}

private func handleSessionResumption(sessionID: UUID) {
    guard let session = currentHistorySession,
          session.sessionID == sessionID else {
        AppLogger.ble.bleError("❌ Session mismatch during resumption")
        abortHistorySession(reason: "Session ID mismatch")
        return
    }
    
    AppLogger.ble.info("✅ Session resumption - preparing to continue from index \(session.currentIndex)")
    
    // Reset failure counters since we successfully reconnected
    currentHistorySession?.consecutiveFailures = 0
    
    // Mark as connected and ready to resume
    isConnected = true
    connectionAttemptContext = .newSession // Reset for next time
}

// Enhanced characteristics discovery for session resumption
func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    // ... existing characteristic discovery code ...
    
    // Check if we need to resume a session
    if let session = currentHistorySession,
       historyControlCharacteristic != nil && 
       historyDataCharacteristic != nil && 
       deviceTimeCharacteristic != nil {
        
        AppLogger.ble.info("🔄 Resuming history session from index \(session.currentIndex)")
        resumeHistoryDataFlow(from: session.currentIndex)
    }
    // ... rest of existing code ...
}
```

### 5. Enhanced History Flow Management

```swift
private func startHistoryDataFlow() {
    // Create new session state
    guard let deviceUUID = self.deviceUUID else {
        AppLogger.ble.bleError("No device UUID for history session")
        return
    }
    
    let sessionID = UUID()
    currentHistorySession = HistorySessionState(
        deviceUUID: deviceUUID,
        totalEntries: 0, // Will be updated when we get entry count
        currentIndex: 0,
        startTime: Date(),
        lastSuccessfulIndex: 0,
        sessionID: sessionID
    )
    
    AppLogger.ble.info("🆕 Starting new history session: \(sessionID)")
    
    // Prevent multiple concurrent history flows
    guard !isHistoryFlowActive else {
        AppLogger.ble.info("⚠️ History flow already active, ignoring request")
        return
    }
    
    // Continue with existing flow...
    isHistoryFlowActive = true
    isCancelled = false
    loadingStateSubject.send(.loading)
    
    // ... rest of existing startHistoryDataFlow code ...
}

private func resumeHistoryDataFlow(from index: Int) {
    guard let session = currentHistorySession else {
        AppLogger.ble.bleError("No session to resume")
        return
    }
    
    AppLogger.ble.info("▶️ Resuming history flow from index \(index)")
    
    // Update session current index
    currentHistorySession?.currentIndex = index
    
    // Resume flow without re-initialization
    isHistoryFlowActive = true
    isCancelled = false
    
    // Update progress and continue fetching
    loadingProgressSubject.send((index, session.totalEntries))
    
    // Small delay to ensure device is ready after reconnection
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if !self.isCancelled && self.isHistoryFlowActive {
            self.fetchHistoricalDataEntry(index: index)
        }
    }
}

// Modified cleanup to preserve session state during disconnects
private func cleanupHistoryFlow() {
    AppLogger.ble.info("🧹 Cleaning up history flow")
    
    // Only mark as inactive, don't destroy session state during disconnects
    isHistoryFlowActive = false
    
    // Cancel all pending timers
    for timer in historyFlowTimers {
        timer.invalidate()
    }
    historyFlowTimers.removeAll()
    
    // Cancel any timeout timers
    requestTimeoutTimer?.invalidate()
    requestTimeoutTimer = nil
    
    // Don't reset session state here - let disconnect handler decide
}

private func finalizeDisconnect() {
    cleanupHistoryFlow()
    currentHistorySession = nil
    
    // Reset all state
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
    
    liveDataRequested = false
    historicalDataRequested = false
    
    resetErrorState()
}

private func abortHistorySession(reason: String) {
    AppLogger.ble.bleError("❌ Aborting history session: \(reason)")
    
    loadingStateSubject.send(.error("History loading failed: \(reason)"))
    
    // Clean up everything
    finalizeDisconnect()
}
```

### 6. Enhanced Progress Tracking

```swift
private func updateSessionProgress(newIndex: Int) {
    guard var session = currentHistorySession else { return }
    
    // Update progress
    let oldIndex = session.currentIndex
    session.currentIndex = newIndex
    session.lastSuccessfulIndex = newIndex
    
    // Reset consecutive failures on successful progress
    if newIndex > oldIndex {
        session.consecutiveFailures = 0
    }
    
    currentHistorySession = session
    
    // Update UI
    loadingProgressSubject.send((newIndex, session.totalEntries))
    
    AppLogger.ble.info("📊 Session progress: \(newIndex)/\(session.totalEntries) (\(String(format: "%.1f", session.progressPercentage * 100))%)")
}

// Modified history data processing to use session state
private func decodeHistoryData(data: Data) {
    guard let session = currentHistorySession else {
        AppLogger.ble.bleError("No active session for history data")
        return
    }
    
    // Check if operation has been cancelled
    if isCancelled {
        AppLogger.ble.info("❌ History data loading was cancelled")
        return
    }
    
    // ... existing decode logic ...
    
    // Update session progress instead of local variables
    if let historicalData = decoder.decodeHistoricalSensorData(data: data) {
        historicalDataSubject.send(historicalData)
        
        let nextIndex = session.currentIndex + 1
        updateSessionProgress(newIndex: nextIndex)
        
        if nextIndex < session.totalEntries && !isCancelled {
            // Continue with next entry
            fetchHistoricalDataEntry(index: nextIndex)
        } else if !isCancelled {
            // Session completed successfully
            AppLogger.ble.info("✅ History session completed successfully")
            loadingStateSubject.send(.completed)
            finalizeDisconnect()
        }
    } else {
        // Handle decode failure
        handleDecodeFailure(at: session.currentIndex)
    }
}

private func handleDecodeFailure(at index: Int) {
    guard var session = currentHistorySession else { return }
    
    session.consecutiveFailures += 1
    currentHistorySession = session
    
    AppLogger.ble.bleError("⚠️ Failed to decode entry \(index) (failure #\(session.consecutiveFailures))")
    
    // If too many consecutive failures, abort
    if session.consecutiveFailures >= 10 {
        abortHistorySession(reason: "Too many consecutive decode failures")
        return
    }
    
    // Otherwise, skip this entry and continue
    let nextIndex = index + 1
    if nextIndex < session.totalEntries {
        AppLogger.ble.info("⏭️ Skipping corrupted entry \(index), continuing with \(nextIndex)")
        updateSessionProgress(newIndex: nextIndex)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.fetchHistoricalDataEntry(index: nextIndex)
        }
    } else {
        // Reached end with failures
        AppLogger.ble.info("✅ History session completed with some failures")
        loadingStateSubject.send(.completed)
        finalizeDisconnect()
    }
}
```

## Summary

This solution provides:

1. **Persistent Session State** - Maintains progress across disconnects
2. **Intelligent Reconnection** - Exponential backoff with reason-based delays  
3. **Loop Prevention** - Limits disconnects per session and detects patterns
4. **Seamless Resumption** - Continues exactly where it left off
5. **Enhanced Monitoring** - Tracks session health and progress
6. **Graceful Degradation** - Aborts only when truly necessary

The key improvement is that **disconnects no longer restart the entire loading process** - they become temporary interruptions that are intelligently handled while preserving all progress.