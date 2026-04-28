//
//  Item.swift
//  EightyFiveBlends
//
//  Created by Julian FIgueroa on 4/27/26.
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
