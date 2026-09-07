import Foundation
import SwiftData

/// A restaurant / eating-out option. Functions much like a Recipe in the
/// planner: it can be assigned to a day and viewed by the whole family.
@Model
final class Restaurant {
    @Attribute(.unique) var id: UUID
    var name: String
    var cuisine: String?
    var notes: String?
    var websiteURL: String?
    /// Free-text address, used to look the place up on a map and to build
    /// the "open in Google Maps" link.
    var address: String?
    var isFavorite: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        cuisine: String? = nil,
        notes: String? = nil,
        websiteURL: String? = nil,
        address: String? = nil,
        isFavorite: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.cuisine = cuisine
        self.notes = notes
        self.websiteURL = websiteURL
        self.address = address
        self.isFavorite = isFavorite
        self.createdAt = createdAt
    }
}
