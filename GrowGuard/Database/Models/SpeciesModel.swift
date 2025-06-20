//
//  SpeciesModel.swift
//  GrowGuard
//
//  Created by veitprogl on 25.05.25.
//
import GRDB

struct Species: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64
    var scientificNname: String
    var light: Int?
    var soilNutriments: String?
    var soilSalinity: String?
    var atmosphericHumidity: String?
    var imageUrl: String?
    var family: String?
    var maxMoisture: Int?
    var minMoisture: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case scientificNname = "scientific_name"
        case soilNutriments = "soil_nutriments"
        case soilSalinity = "soil_salinity"
        case atmosphericHumidity = "atmospheric_humidity"
        case imageUrl = "image_url"
        case family = "family"
        case maxMoisture = "soil_moisture_max"
        case minMoisture = "soil_moisture_min"
    }
    
    enum Columns {
        static let scientificName = Column("scientific_name")
    }
}
