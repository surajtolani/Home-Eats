import Foundation
import SwiftData

enum MealRating: Int, Codable {
    case disliked = 0
    case neutral = 1
    case liked = 2
}

/// A record that a recipe or restaurant meal actually happened, as opposed
/// to just being planned. This is what powers the "made before / liked
/// before" recommendation signal, and is separate from `PlannedMeal` because
/// a planned meal can slip (travel changed, took out food instead) and we
/// only want to learn from what really happened.
@Model
final class MealHistoryEntry {
    @Attribute(.unique) var id: UUID
    var date: Date
    var recipeID: UUID?
    var restaurantID: UUID?
    var rating: MealRating?
    var madeByMemberID: UUID?
    var notes: String?
    /// This entry's id on the backend's `MealHistoryEntry` table, once
    /// pushed there — `nil` until `PersonalLibrarySyncService.syncMealHistory`
    /// first creates it server-side, same role `Restaurant.backendID`/
    /// `Recipe.backendRecipeID` already play for those two models. Before
    /// this existed, meal history lived purely on-device with no server
    /// copy at all, so a local-store reset or a second device could never
    /// recover or see it. See `PersonalLibrarySyncService`'s own doc
    /// comment for the full sync design.
    var backendID: String?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        recipeID: UUID? = nil,
        restaurantID: UUID? = nil,
        rating: MealRating? = nil,
        madeByMemberID: UUID? = nil,
        notes: String? = nil,
        backendID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.recipeID = recipeID
        self.restaurantID = restaurantID
        self.rating = rating
        self.madeByMemberID = madeByMemberID
        self.notes = notes
        self.backendID = backendID
    }
}
