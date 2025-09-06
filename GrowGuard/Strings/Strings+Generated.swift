// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
internal enum L10n {
  internal enum Alert {
    /// Cancel
    internal static let cancel = L10n.tr("Localizable", "alert.cancel", fallback: "Cancel")
    /// Copied
    internal static let copied = L10n.tr("Localizable", "alert.copied", fallback: "Copied")
    /// Delete
    internal static let delete = L10n.tr("Localizable", "alert.delete", fallback: "Delete")
    /// Error
    internal static let error = L10n.tr("Localizable", "alert.error", fallback: "Error")
    /// Export Error
    internal static let exportError = L10n.tr("Localizable", "alert.exportError", fallback: "Export Error")
    /// Export Successful
    internal static let exportSuccessful = L10n.tr("Localizable", "alert.exportSuccessful", fallback: "Export Successful")
    /// Alerts
    internal static let info = L10n.tr("Localizable", "alert.info", fallback: "Info")
    /// OK
    internal static let ok = L10n.tr("Localizable", "alert.ok", fallback: "OK")
    /// Save
    internal static let save = L10n.tr("Localizable", "alert.save", fallback: "Save")
    /// Save Error
    internal static let saveError = L10n.tr("Localizable", "alert.saveError", fallback: "Save Error")
  }
  internal enum Appintent {
    /// Device ID:
    internal static let deviceId = L10n.tr("Localizable", "appintent.deviceId", fallback: "Device ID:")
    /// App Intents
    internal static let doSomething = L10n.tr("Localizable", "appintent.doSomething", fallback: "Do something with my app")
    /// Reload data for single device
    internal static let reloadDevice = L10n.tr("Localizable", "appintent.reloadDevice", fallback: "Reload data for single device")
  }
  internal enum Clipboard {
    /// Clipboard
    internal static let idCopied = L10n.tr("Localizable", "clipboard.idCopied", fallback: "ID copied to clipboard")
  }
  internal enum Common {
    /// Unknown Device
    internal static let defaultDevice = L10n.tr("Localizable", "common.defaultDevice", fallback: "Unknown Device")
    /// Common
    internal static let error = L10n.tr("Localizable", "common.error", fallback: "error")
  }
  internal enum Debug {
    /// Debug Tools
    internal static let menu = L10n.tr("Localizable", "debug.menu", fallback: "Debug Menu")
  }
  internal enum Device {
    /// Device Management
    internal static let addWithoutSensor = L10n.tr("Localizable", "device.addWithoutSensor", fallback: "Add without Sensor")
    /// Available Sensors
    internal static let availableSensors = L10n.tr("Localizable", "device.availableSensors", fallback: "Available Sensors")
    /// Blink
    internal static let blink = L10n.tr("Localizable", "device.blink", fallback: "Blink")
    /// Delete Device
    internal static let delete = L10n.tr("Localizable", "device.delete", fallback: "Delete Device")
    /// Are you sure you want to delete '%@'? This will also delete all associated sensor data and cannot be undone.
    internal static func deleteConfirmation(_ p1: Any) -> String {
      return L10n.tr("Localizable", "device.deleteConfirmation", String(describing: p1), fallback: "Are you sure you want to delete '%@'? This will also delete all associated sensor data and cannot be undone.")
    }
    /// ID: 
    internal static let id = L10n.tr("Localizable", "device.id", fallback: "ID: ")
    /// Last Update: 
    internal static let lastUpdate = L10n.tr("Localizable", "device.lastUpdate", fallback: "Last Update: ")
    /// Load Historical Data
    internal static let loadHistoricalData = L10n.tr("Localizable", "device.loadHistoricalData", fallback: "Load Historical Data")
    /// Device Name
    internal static let name = L10n.tr("Localizable", "device.name", fallback: "Device Name")
    /// This plant does not have a sensor attached. You need to manage the watering manually.
    internal static let noSensorMessage = L10n.tr("Localizable", "device.noSensorMessage", fallback: "This plant does not have a sensor attached. You need to manage the watering manually.")
    /// Search Flower
    internal static let searchFlower = L10n.tr("Localizable", "device.searchFlower", fallback: "Search Flower")
    /// You can use this ID to setup a shortcut to this device in the Shortcuts app. This will allow you to quickly refresh the device's data and setup automations without having to open the app.
    internal static let shortcutInfo = L10n.tr("Localizable", "device.shortcutInfo", fallback: "You can use this ID to setup a shortcut to this device in the Shortcuts app. This will allow you to quickly refresh the device's data and setup automations without having to open the app.")
    /// Unknown Device
    internal static let unknownDevice = L10n.tr("Localizable", "device.unknownDevice", fallback: "Unknown Device")
    internal enum Error {
      /// Device Errors
      internal static let alreadyAdded = L10n.tr("Localizable", "device.error.alreadyAdded", fallback: "The Device is already added!")
      /// Bluetooth is not available.
      internal static let bluetoothUnavailable = L10n.tr("Localizable", "device.error.bluetoothUnavailable", fallback: "Bluetooth is not available.")
      /// Failed to delete data
      internal static let deleteFailed = L10n.tr("Localizable", "device.error.deleteFailed", fallback: "Failed to delete data")
      /// Failed to fetch data
      internal static let fetchFailed = L10n.tr("Localizable", "device.error.fetchFailed", fallback: "Failed to fetch data")
      /// Error fetching devices: %@
      internal static func fetchingDevices(_ p1: Any) -> String {
        return L10n.tr("Localizable", "device.error.fetchingDevices", String(describing: p1), fallback: "Error fetching devices: %@")
      }
      /// The Device name already exists, please pick a unique one
      internal static let nameExists = L10n.tr("Localizable", "device.error.nameExists", fallback: "The Device name already exists, please pick a unique one")
      /// Device not found
      internal static let notFound = L10n.tr("Localizable", "device.error.notFound", fallback: "Device not found")
      /// Failed to save data
      internal static let saveFailed = L10n.tr("Localizable", "device.error.saveFailed", fallback: "Failed to save data")
    }
  }
  internal enum Error {
    /// Error Messages
    internal static let loadingData = L10n.tr("Localizable", "error.loadingData", fallback: "Failed to load data")
  }
  internal enum History {
    /// No Data Available
    internal static let noData = L10n.tr("Localizable", "history.noData", fallback: "No Data Available")
    /// Start collecting sensor data to see historical entries here.
    internal static let noDataDescription = L10n.tr("Localizable", "history.noDataDescription", fallback: "Start collecting sensor data to see historical entries here.")
    /// History
    internal static let title = L10n.tr("Localizable", "history.title", fallback: "History")
    /// View All History
    internal static let viewAll = L10n.tr("Localizable", "history.viewAll", fallback: "View All History")
  }
  internal enum Navigation {
    /// Add
    internal static let add = L10n.tr("Localizable", "navigation.add", fallback: "Add")
    /// Add Device
    internal static let addDevice = L10n.tr("Localizable", "navigation.addDevice", fallback: "Add Device")
    /// Add Device Details
    internal static let addDeviceDetails = L10n.tr("Localizable", "navigation.addDeviceDetails", fallback: "Add Device Details")
    /// Debug Tools
    internal static let debugTools = L10n.tr("Localizable", "navigation.debugTools", fallback: "Debug Tools")
    /// Main Navigation
    internal static let menu = L10n.tr("Localizable", "navigation.menu", fallback: "Menu")
    /// Overview
    internal static let overview = L10n.tr("Localizable", "navigation.overview", fallback: "Overview")
    /// Select Flower
    internal static let selectFlower = L10n.tr("Localizable", "navigation.selectFlower", fallback: "Select Flower")
    /// Settings
    internal static let settings = L10n.tr("Localizable", "navigation.settings", fallback: "Settings")
  }
  internal enum Notification {
    /// Notifications
    internal static let debugTest = L10n.tr("Localizable", "notification.debugTest", fallback: "🧪 Debug: Test Notifications")
    /// Pending: 
    internal static let pending = L10n.tr("Localizable", "notification.pending", fallback: "Pending: ")
    /// %d notifications
    internal static func pendingCount(_ p1: Int) -> String {
      return L10n.tr("Localizable", "notification.pendingCount", p1, fallback: "%d notifications")
    }
    /// Refresh
    internal static let refresh = L10n.tr("Localizable", "notification.refresh", fallback: "Refresh")
    /// Request Permission
    internal static let requestPermission = L10n.tr("Localizable", "notification.requestPermission", fallback: "Request Permission")
    /// Schedule a test notification to verify push messages work
    internal static let scheduleTest = L10n.tr("Localizable", "notification.scheduleTest", fallback: "Schedule a test notification to verify push messages work")
    /// ⚠️ IMPORTANT: iOS Simulator often doesn't show notifications!
    internal static let simulatorWarning = L10n.tr("Localizable", "notification.simulatorWarning", fallback: "⚠️ IMPORTANT: iOS Simulator often doesn't show notifications!")
    /// Status: 
    internal static let status = L10n.tr("Localizable", "notification.status", fallback: "Status: ")
    /// Notification Time
    internal static let time = L10n.tr("Localizable", "notification.time", fallback: "Notification Time")
    /// Time from now: 
    internal static let timeFromNow = L10n.tr("Localizable", "notification.timeFromNow", fallback: "Time from now: ")
  }
  internal enum Onboarding {
    /// Add Device
    internal static let addDevice = L10n.tr("Localizable", "onboarding.addDevice", fallback: "Add Device")
    /// This app is designed to help you take care of your plants.
    internal static let description = L10n.tr("Localizable", "onboarding.description", fallback: "This app is designed to help you take care of your plants.")
    /// See your current environment conditions of your plants
    internal static let feature1 = L10n.tr("Localizable", "onboarding.feature1", fallback: "See your current environment conditions of your plants")
    /// Get notified when something is wrong
    internal static let feature2 = L10n.tr("Localizable", "onboarding.feature2", fallback: "Get notified when something is wrong")
    /// Add multiple devices to monitor multiple plants
    internal static let feature3 = L10n.tr("Localizable", "onboarding.feature3", fallback: "Add multiple devices to monitor multiple plants")
    /// Features
    internal static let features = L10n.tr("Localizable", "onboarding.features", fallback: "Features")
    /// To get started, please add a new device.
    internal static let getStarted = L10n.tr("Localizable", "onboarding.getStarted", fallback: "To get started, please add a new device.")
    /// Onboarding
    internal static let welcome = L10n.tr("Localizable", "onboarding.welcome", fallback: "Welcome to GrowGuard")
  }
  internal enum Plant {
    /// Plant Selection
    internal static let addFlower = L10n.tr("Localizable", "plant.addFlower", fallback: "Add Flower")
    /// Values automatically set from selected plant
    internal static let autoValues = L10n.tr("Localizable", "plant.autoValues", fallback: "Values automatically set from selected plant")
    /// Change
    internal static let change = L10n.tr("Localizable", "plant.change", fallback: "Change")
    /// Currently Selected:
    internal static let currentlySelected = L10n.tr("Localizable", "plant.currentlySelected", fallback: "Currently Selected:")
    /// Recommended Moisture: %d%% - %d%%
    internal static func recommendedMoisture(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "plant.recommendedMoisture", p1, p2, fallback: "Recommended Moisture: %d%% - %d%%")
    }
    /// Remove
    internal static let remove = L10n.tr("Localizable", "plant.remove", fallback: "Remove")
    /// Remove Plant
    internal static let removePlant = L10n.tr("Localizable", "plant.removePlant", fallback: "Remove Plant")
    /// Enter a flower name to find optimal growing conditions and care recommendations.
    internal static let searchDescription = L10n.tr("Localizable", "plant.searchDescription", fallback: "Enter a flower name to find optimal growing conditions and care recommendations.")
    /// Search for a flower
    internal static let searchPrompt = L10n.tr("Localizable", "plant.searchPrompt", fallback: "Search for a flower")
    /// Search Results
    internal static let searchResults = L10n.tr("Localizable", "plant.searchResults", fallback: "Search Results")
    /// Plant: %@
    internal static func selectedPlant(_ p1: Any) -> String {
      return L10n.tr("Localizable", "plant.selectedPlant", String(describing: p1), fallback: "Plant: %@")
    }
    /// Plant Selection
    internal static let selection = L10n.tr("Localizable", "plant.selection", fallback: "Plant Selection")
    /// Select Plant
    internal static let selectPlant = L10n.tr("Localizable", "plant.selectPlant", fallback: "Select Plant")
    /// Soil Moisture: %d%% - %d%%
    internal static func soilMoisture(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "plant.soilMoisture", p1, p2, fallback: "Soil Moisture: %d%% - %d%%")
    }
    /// Will update your moisture settings
    internal static let updateSettings = L10n.tr("Localizable", "plant.updateSettings", fallback: "Will update your moisture settings")
  }
  internal enum Pot {
    /// Accept calculation
    internal static let acceptCalculation = L10n.tr("Localizable", "pot.acceptCalculation", fallback: "Accept calculation")
    /// Automatically calculated volume: %.1f cm³
    internal static func calculatedVolume(_ p1: Float) -> String {
      return L10n.tr("Localizable", "pot.calculatedVolume", p1, fallback: "Automatically calculated volume: %.1f cm³")
    }
    /// Current fill volume: %.1fl
    internal static func currentFill(_ p1: Float) -> String {
      return L10n.tr("Localizable", "pot.currentFill", p1, fallback: "Current fill volume: %.1fl")
    }
    /// Pot height (cm)
    internal static let height = L10n.tr("Localizable", "pot.height", fallback: "Pot height (cm)")
    /// Max pot volume: %.1fl
    internal static func maxVolume(_ p1: Float) -> String {
      return L10n.tr("Localizable", "pot.maxVolume", p1, fallback: "Max pot volume: %.1fl")
    }
    /// Pot radius (cm)
    internal static let radius = L10n.tr("Localizable", "pot.radius", fallback: "Pot radius (cm)")
    /// Pot Configuration
    internal static let section = L10n.tr("Localizable", "pot.section", fallback: "Flower Pot")
    /// Pot volume
    internal static let volume = L10n.tr("Localizable", "pot.volume", fallback: "Pot volume")
    /// Volume can be automatically calculated, but if you know yours please enter it here to be more precise
    internal static let volumeDescription = L10n.tr("Localizable", "pot.volumeDescription", fallback: "Volume can be automatically calculated, but if you know yours please enter it here to be more precise")
    /// 100ml
    internal static let volumeUnit = L10n.tr("Localizable", "pot.volumeUnit", fallback: "100ml")
  }
  internal enum Sensor {
    /// Sensor Parameters
    internal static let brightness = L10n.tr("Localizable", "sensor.brightness", fallback: "Brightness")
    /// Conductivity
    internal static let conductivity = L10n.tr("Localizable", "sensor.conductivity", fallback: "Conductivity")
    /// Current Value: %@
    internal static func currentValue(_ p1: Any) -> String {
      return L10n.tr("Localizable", "sensor.currentValue", String(describing: p1), fallback: "Current Value: %@")
    }
    /// Sensor Data
    internal static let data = L10n.tr("Localizable", "sensor.data", fallback: "Sensor Data")
    /// Loading week data...
    internal static let loadingWeekData = L10n.tr("Localizable", "sensor.loadingWeekData", fallback: "Loading week data...")
    /// Max Brightness
    internal static let maxBrightness = L10n.tr("Localizable", "sensor.maxBrightness", fallback: "Max Brightness")
    /// Max Conductivity
    internal static let maxConductivity = L10n.tr("Localizable", "sensor.maxConductivity", fallback: "Max Conductivity")
    /// Max Moisture
    internal static let maxMoisture = L10n.tr("Localizable", "sensor.maxMoisture", fallback: "Max Moisture")
    /// Max Temperature
    internal static let maxTemperature = L10n.tr("Localizable", "sensor.maxTemperature", fallback: "Max Temperature")
    /// Min Brightness
    internal static let minBrightness = L10n.tr("Localizable", "sensor.minBrightness", fallback: "Min Brightness")
    /// Min Conductivity
    internal static let minConductivity = L10n.tr("Localizable", "sensor.minConductivity", fallback: "Min Conductivity")
    /// Min Moisture
    internal static let minMoisture = L10n.tr("Localizable", "sensor.minMoisture", fallback: "Min Moisture")
    /// Min Temperature
    internal static let minTemperature = L10n.tr("Localizable", "sensor.minTemperature", fallback: "Min Temperature")
    /// Moisture
    internal static let moisture = L10n.tr("Localizable", "sensor.moisture", fallback: "Moisture")
    /// No data available
    internal static let noData = L10n.tr("Localizable", "sensor.noData", fallback: "No data available")
    /// No data available for this week
    internal static let noDataWeek = L10n.tr("Localizable", "sensor.noDataWeek", fallback: "No data available for this week")
    /// %@ Range
    internal static func range(_ p1: Any) -> String {
      return L10n.tr("Localizable", "sensor.range", String(describing: p1), fallback: "%@ Range")
    }
    /// Temperature
    internal static let temperature = L10n.tr("Localizable", "sensor.temperature", fallback: "Temperature")
    internal enum Unit {
      /// C
      internal static let celsius = L10n.tr("Localizable", "sensor.unit.celsius", fallback: "C")
      /// lux
      internal static let lux = L10n.tr("Localizable", "sensor.unit.lux", fallback: "lux")
      /// %
      internal static let percent = L10n.tr("Localizable", "sensor.unit.percent", fallback: "%")
    }
  }
  internal enum Settings {
    /// Removes impossible sensor values like moisture > 100%, extreme temperatures, etc.
    internal static let cleanDescription = L10n.tr("Localizable", "settings.cleanDescription", fallback: "Removes impossible sensor values like moisture > 100%, extreme temperatures, etc.")
    /// Cleaning...
    internal static let cleaning = L10n.tr("Localizable", "settings.cleaning", fallback: "Cleaning...")
    /// Clean Invalid Data
    internal static let cleanInvalidData = L10n.tr("Localizable", "settings.cleanInvalidData", fallback: "Clean Invalid Data")
    /// Settings
    internal static let databaseMaintenance = L10n.tr("Localizable", "settings.databaseMaintenance", fallback: "Database Maintenance")
    /// Invalid entries: %d
    internal static func invalidEntries(_ p1: Int) -> String {
      return L10n.tr("Localizable", "settings.invalidEntries", p1, fallback: "Invalid entries: %d")
    }
    /// Loading...
    internal static let loading = L10n.tr("Localizable", "settings.loading", fallback: "Loading...")
    /// Saving...
    internal static let saving = L10n.tr("Localizable", "settings.saving", fallback: "Saving...")
    /// Total entries: %d
    internal static func totalEntries(_ p1: Int) -> String {
      return L10n.tr("Localizable", "settings.totalEntries", p1, fallback: "Total entries: %d")
    }
  }
  internal enum Userdefaults {
    /// App Configuration
    internal static let showOnboarding = L10n.tr("Localizable", "userdefaults.showOnboarding", fallback: "veit.pro.showOnboarding")
  }
  internal enum Watering {
    /// Confidence: %@
    internal static func confidence(_ p1: Any) -> String {
      return L10n.tr("Localizable", "watering.confidence", String(describing: p1), fallback: "Confidence: %@")
    }
    /// Current: %d%%
    internal static func current(_ p1: Int) -> String {
      return L10n.tr("Localizable", "watering.current", p1, fallback: "Current: %d%%")
    }
    /// %.1f%%/day drying
    internal static func dryingRate(_ p1: Float) -> String {
      return L10n.tr("Localizable", "watering.dryingRate", p1, fallback: "%.1f%%/day drying")
    }
    /// Last watered:
    internal static let lastWatered = L10n.tr("Localizable", "watering.lastWatered", fallback: "Last watered:")
    /// Your plant needs water today
    internal static let neededToday = L10n.tr("Localizable", "watering.neededToday", fallback: "Your plant needs water today")
    /// Next watering needed:
    internal static let nextNeeded = L10n.tr("Localizable", "watering.nextNeeded", fallback: "Next watering needed:")
    /// Watering Prediction
    internal static let prediction = L10n.tr("Localizable", "watering.prediction", fallback: "Watering Prediction")
    /// Target: %d%%
    internal static func target(_ p1: Int) -> String {
      return L10n.tr("Localizable", "watering.target", p1, fallback: "Target: %d%%")
    }
    /// Watering
    internal static let urgentNow = L10n.tr("Localizable", "watering.urgentNow", fallback: "Urgent: Water Needed Now!")
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}
// swiftlint:enable convenience_type
