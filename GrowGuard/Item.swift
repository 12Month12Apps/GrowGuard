//
//  Item.swift
//  GrowGuard
//
//  Created by Veit Progl on 28.04.24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
