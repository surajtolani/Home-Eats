import Foundation
import SwiftData

enum MealRating: Int, Codable {
    case disliked = 0
    case neutral = 1
    case liked = 2
}

/// A record that a recipe or restaurant meal actually happened, as opposed
/// to just being planned. This is what powers the "made before / liked
/// before" recommendation signal, and is separate from `DayPlan` because a
/// planned day can slip (travel changed, took out food instead) and we only
/// want to learn from what really happened.
@Model
final class MealHistoryEntry {
    @Attribute(.unique) var id: UUID
    var date: Date
    var recipeID: UUID?
    var restaurantID: UUID?
    var rating: MealRating?
    var madeByMemberID: UUID?
    var notes: String?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        recipeID: UUID? = nil,
        restaurantID: UUID? = nil,
        rating: MealRating? = nil,
        madeByMemberID: UUID? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.date = date
        self.recipeID = recipeID
        self.restaurantID = restaurantID
        self.rating = rating
        self.madeByMemberID = madeByMemberID
        self.notes = notes
    }
}
