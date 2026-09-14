import Foundation

protocol FlowerDeviceRepository {
    func getAllDevices() async throws -> [FlowerDeviceDTO]
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO?
    func saveDevice(_ device: FlowerDeviceDTO) async throws
    func deleteDevice(uuid: String) async throws
    func updateDevice(_ device: FlowerDeviceDTO) async throws
}

extension FlowerDeviceRepository {
    /// Fetch → mutate → save. Callers change only the fields they own on a
    /// freshly loaded copy, so a long-lived stale DTO (e.g. a view model's
    /// `device`) never writes old values back over fields another writer
    /// owns. NOT atomic: two concurrent calls on the same uuid still race
    /// across the awaits; all current writers run on the main actor, which
    /// keeps that window small but not zero. Returns nil for unknown devices.
    @discardableResult
    func modifyDevice(uuid: String, _ mutate: (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO? {
        guard var device = try await getDevice(by: uuid) else { return nil }
        mutate(&device)
        try await updateDevice(device)
        return device
    }
}
