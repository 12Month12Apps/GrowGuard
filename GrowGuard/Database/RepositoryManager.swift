import Foundation
import CoreData

class RepositoryManager {
    static let shared = RepositoryManager()
    
    let flowerDeviceRepository: FlowerDeviceRepository
    let sensorDataRepository: SensorDataRepository
    let optimalRangeRepository: OptimalRangeRepository
    let potSizeRepository: PotSizeRepository
    
    private init() {
        let context = DataService.shared.context
        
        self.flowerDeviceRepository = CoreDataFlowerDeviceRepository(context: context)
        self.sensorDataRepository = CoreDataSensorDataRepository(context: context)
        self.optimalRangeRepository = CoreDataOptimalRangeRepository(context: context)
        self.potSizeRepository = CoreDataPotSizeRepository(context: context)
    }
}