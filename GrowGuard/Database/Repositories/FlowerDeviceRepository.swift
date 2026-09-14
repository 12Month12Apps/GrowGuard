import Foundation

protocol FlowerDeviceRepository {
    func getAllDevices() async throws -> [FlowerDeviceDTO]
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO?
    func saveDevice(_ device: FlowerDeviceDTO) async throws
    func deleteDevice(uuid: String) async throws
    func updateDevice(_ device: FlowerDeviceDTO) async throws
}

extension FlowerDeviceRepository {
    /// Fetch → mutate → save. Callers change only the fields they own, so a
    /// stale full copy never overwrites what another writer (for example
    /// SensorHealthMonitor) just persisted. Returns nil for unknown devices.
    @discardableResult
    func modifyDevice(uuid: String, _ mutate: (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO? {
        guard var device = try await getDevice(by: uuid) else { return nil }
        mutate(&device)
        try await updateDevice(device)
        return device
    }
}
