import Foundation

protocol FlowerDeviceRepository {
    func getAllDevices() async throws -> [FlowerDeviceDTO]
    func getDevice(by uuid: String) async throws -> FlowerDeviceDTO?
    func saveDevice(_ device: FlowerDeviceDTO) async throws
    func deleteDevice(uuid: String) async throws
    func updateDevice(_ device: FlowerDeviceDTO) async throws
}