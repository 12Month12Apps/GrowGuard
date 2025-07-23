import Foundation

enum RepositoryError: Error, LocalizedError {
    case deviceNotFound
    case saveFailed
    case deleteFailed
    case fetchFailed
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Device not found"
        case .saveFailed:
            return "Failed to save data"
        case .deleteFailed:
            return "Failed to delete data"
        case .fetchFailed:
            return "Failed to fetch data"
        }
    }
}