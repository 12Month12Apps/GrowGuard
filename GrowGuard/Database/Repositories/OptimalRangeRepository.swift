import Foundation

protocol OptimalRangeRepository {
    func getOptimalRange(for deviceUUID: String) async throws -> OptimalRangeDTO?
    func saveOptimalRange(_ optimalRange: OptimalRangeDTO) async throws
    func deleteOptimalRange(for deviceUUID: String) async throws
}