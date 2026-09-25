import Foundation

protocol FlowerDeviceRepository {
    func getAllDevices() async throws -> [FlowerDeviceDTO]
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO?
    func saveDevice(_ device: FlowerDeviceDTO) async throws
    func deleteDevice(uuid: String) async throws
    func updateDevice(_ device: FlowerDeviceDTO) async throws

    /// Read → mutate → write for one device. Callers change only the fields
    /// they own on a freshly loaded copy, so a long-lived stale DTO (e.g. a
    /// view model's `device`) never writes old values back over fields another
    /// writer owns. Returns nil for unknown devices, having written nothing.
    ///
    /// A requirement, not just an extension, so an implementation can make the
    /// whole sequence atomic — `CoreDataFlowerDeviceRepository` does.
    @discardableResult
    func modifyDevice(uuid: String, _ mutate: @escaping (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO?
}

extension FlowerDeviceRepository {
    /// Default implementation: three separate awaits — get, mutate, update.
    /// **NOT atomic**: two concurrent calls on the same uuid read the same row
    /// and the later write wins, dropping the earlier one's field. Fine for the
    /// in-memory fakes the tests use; the Core Data implementation overrides
    /// this with a single serialized transaction and is atomic.
    @discardableResult
    func modifyDevice(uuid: String, _ mutate: @escaping (inout FlowerDeviceDTO) -> Void) async throws -> FlowerDeviceDTO? {
        guard var device = try await getDevice(by: uuid) else { return nil }
        mutate(&device)
        try await updateDevice(device)
        return device
    }
}
