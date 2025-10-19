import Foundation
import CoreData

class RepositoryManager {
    static let shared = RepositoryManager()
    
    let flowerDeviceRepository: FlowerDeviceRepository
    let sensorDataRepository: SensorDataRepository
    let optimalRangeRepository: OptimalRangeRepository
    let potSizeRepository: PotSizeRepository
    
    private init() {
        // Use dedicated background contexts so Core Data work never blocks the main thread
        self.flowerDeviceRepository = CoreDataFlowerDeviceRepository()
        self.sensorDataRepository = CoreDataSensorDataRepository()
        self.optimalRangeRepository = CoreDataOptimalRangeRepository()
        self.potSizeRepository = CoreDataPotSizeRepository()
    }
}
