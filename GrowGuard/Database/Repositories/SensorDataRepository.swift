import Foundation

protocol SensorDataRepository {
    func getSensorData(for deviceUUID: String, limit: Int?) async throws -> [SensorDataDTO]
    func getRecentSensorData(for deviceUUID: String, limit: Int) async throws -> [SensorDataDTO]
    func saveSensorData(_ sensorData: SensorDataDTO) async throws
    func deleteSensorData(id: String) async throws
    func deleteAllSensorData(for deviceUUID: String) async throws
}