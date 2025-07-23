import Foundation

protocol PotSizeRepository {
    func getPotSize(for deviceUUID: String) async throws -> PotSizeDTO?
    func savePotSize(_ potSize: PotSizeDTO) async throws
    func deletePotSize(for deviceUUID: String) async throws
}