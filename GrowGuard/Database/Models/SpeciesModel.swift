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
    
    enum CodingKeys: String, CodingKey {
        case id
        case scientificNname = "scientific_name"
        case soilNutriments = "soil_nutriments"
        case soilSalinity = "soil_salinity"
        case atmosphericHumidity = "atmospheric_humidity"
        case imageUrl = "image_url"
    }
}
