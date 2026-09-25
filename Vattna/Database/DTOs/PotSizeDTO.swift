import Foundation

struct PotSizeDTO: Identifiable, Hashable {
    let id: String
    var width: Double
    var height: Double
    var volume: Double
    let deviceUUID: String
    
    init(
        id: String = UUID().uuidString,
        width: Double = 0.0,
        height: Double = 0.0,
        volume: Double = 0.0,
        deviceUUID: String
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.volume = volume
        self.deviceUUID = deviceUUID
    }
}
