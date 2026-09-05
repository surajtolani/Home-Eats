import Foundation
import SwiftData

/// A person in the household who can view the plan and make or suggest
/// meal selections. Selections are always tied back to a FamilyMember so
/// preferences stay visible (e.g. Dad's weekend picks vs. the kids' weekday picks).
@Model
final class FamilyMember {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Hex string like "FF7A59" used as an accent color badge throughout the UI.
    var colorHex: String
    var isChild: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "4E9F3D",
        isChild: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isChild = isChild
        self.createdAt = createdAt
    }

    static let householdPlaceholderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
