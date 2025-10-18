//
//  SpeciesModel.swift
//  GrowGuard
//
//  Created by veitprogl on 25.05.25.
//
import GRDB

struct Species: Decodable, FetchableRecord, Identifiable {
    var id: Int64
    var scientificNname: String
    var imageUrl: String?
    var family: String?
    var maxMoisture: Int?
    var minMoisture: Int?
    var commonNames: [String]
    
    enum CodingKeys: String, CodingKey {
        case id
        case scientificNname = "scientific_name"
        case imageUrl = "url_image"
        case family = "family_name"
        case maxMoisture = "max_moisture"
        case minMoisture = "min_moisture"
        case commonNames = "common_names"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        scientificNname = try container.decode(String.self, forKey: .scientificNname)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        family = try container.decodeIfPresent(String.self, forKey: .family)
        maxMoisture = try container.decodeIfPresent(Int.self, forKey: .maxMoisture)
        minMoisture = try container.decodeIfPresent(Int.self, forKey: .minMoisture)
        if let rawCommonNames = try container.decodeIfPresent(String.self, forKey: .commonNames),
           rawCommonNames.isEmpty == false {
            commonNames = rawCommonNames.split(separator: "|").map { String($0) }
        } else {
            commonNames = []
        }
    }
}
