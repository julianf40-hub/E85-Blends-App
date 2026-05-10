//
//  MaintenanceReminder.swift
//  EightyFiveBlends
//
//  Created by Codex on 4/27/26.
//

import Foundation
import SwiftData

@Model
final class MaintenanceReminder {
    var vehicleName: String
    var title: String
    var category: String
    var mileageEnabled: Bool
    var dueMileage: Int
    var repeatMileageInterval: Int
    var dateEnabled: Bool
    var dueDate: Date
    var repeatDateIntervalDays: Int
    var notes: String
    var purchaseURLString: String?
    var purchaseLinksJSON: String?
    var isCompleted: Bool
    var completedAt: Date?
    var completedMileage: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        vehicleName: String = "",
        title: String = "",
        category: String = "",
        mileageEnabled: Bool = false,
        dueMileage: Int = 0,
        repeatMileageInterval: Int = 0,
        dateEnabled: Bool = false,
        dueDate: Date = .now,
        repeatDateIntervalDays: Int = 0,
        notes: String = "",
        purchaseURLString: String? = nil,
        purchaseLinksJSON: String? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        completedMileage: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.vehicleName = vehicleName
        self.title = title
        self.category = category
        self.mileageEnabled = mileageEnabled
        self.dueMileage = dueMileage
        self.repeatMileageInterval = repeatMileageInterval
        self.dateEnabled = dateEnabled
        self.dueDate = dueDate
        self.repeatDateIntervalDays = repeatDateIntervalDays
        self.notes = notes
        self.purchaseURLString = purchaseURLString
        self.purchaseLinksJSON = purchaseLinksJSON
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.completedMileage = completedMileage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ReminderPurchaseLink: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var urlString: String

    init(id: UUID = UUID(), label: String = "", urlString: String = "") {
        self.id = id
        self.label = label
        self.urlString = urlString
    }
}

extension MaintenanceReminder {
    var purchaseLinks: [ReminderPurchaseLink] {
        let decodedLinks = Self.decodePurchaseLinks(from: purchaseLinksJSON)
        if decodedLinks.isEmpty == false {
            return decodedLinks
        }

        guard let purchaseURLString,
              let normalizedURLString = Self.normalizedPurchaseURLString(from: purchaseURLString) else {
            return []
        }

        return [ReminderPurchaseLink(label: "Parts Link", urlString: normalizedURLString)]
    }

    static func encodePurchaseLinks(_ links: [ReminderPurchaseLink]) -> String? {
        let normalizedLinks = normalizedPurchaseLinks(links)
        guard normalizedLinks.isEmpty == false,
              let data = try? JSONEncoder().encode(normalizedLinks) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func decodePurchaseLinks(from json: String?) -> [ReminderPurchaseLink] {
        guard let json,
              let data = json.data(using: .utf8),
              let links = try? JSONDecoder().decode([ReminderPurchaseLink].self, from: data) else {
            return []
        }

        return normalizedPurchaseLinks(links)
    }

    static func normalizedPurchaseLinks(_ links: [ReminderPurchaseLink]) -> [ReminderPurchaseLink] {
        links.compactMap { link in
            guard let normalizedURLString = normalizedPurchaseURLString(from: link.urlString) else {
                return nil
            }

            let trimmedLabel = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReminderPurchaseLink(
                id: link.id,
                label: trimmedLabel.isEmpty ? "Parts Link" : trimmedLabel,
                urlString: normalizedURLString
            )
        }
    }

    static func normalizedPurchaseURLString(from value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.isEmpty == false else {
            return nil
        }

        let lowercaseValue = trimmedValue.lowercased()
        if lowercaseValue.hasPrefix("http://") || lowercaseValue.hasPrefix("https://") {
            return trimmedValue
        }

        return "https://\(trimmedValue)"
    }
}
