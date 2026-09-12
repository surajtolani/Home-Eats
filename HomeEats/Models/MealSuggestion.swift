import Foundation
import SwiftData

/// A proposal from one family member for what a given day's *specific meal
/// slot* should be, plus a lightweight up-vote list so other members can
/// weigh in without building a full poll/comment system. Scoped by
/// (date, slot) rather than a relationship, since a day is just a date —
/// there's no separate "day" row to hang off of.
@Model
final class MealSuggestion {
    @Attribute(.unique) var id: UUID
    var date: Date
    var slot: MealSlot
    var proposedByMemberID: UUID
    var recipe: Recipe?
    var restaurant: Restaurant?
    /// Only meaningful alongside `restaurant` — distinguishes "vote for
    /// eating out at this place" from "vote for ordering in from this
    /// place," the same distinction `PlannedMeal.isOrderIn` makes once
    /// something's actually decided. Defaulted so this stays a lightweight
    /// migration; `false` for a recipe suggestion (unused there).
    var isOrderIn: Bool = false
    var note: String?
    var createdAt: Date
    /// IDs of family members who upvoted this suggestion (proposer included by default).
    var votedMemberIDs: [UUID]

    init(
        id: UUID = UUID(),
        date: Date,
        slot: MealSlot,
        proposedByMemberID: UUID,
        recipe: Recipe? = nil,
        restaurant: Restaurant? = nil,
        isOrderIn: Bool = false,
        note: String? = nil,
        createdAt: Date = .now,
        votedMemberIDs: [UUID]? = nil
    ) {
        self.id = id
        self.date = PlannedMeal.normalize(date)
        self.slot = slot
        self.proposedByMemberID = proposedByMemberID
        self.recipe = recipe
        self.restaurant = restaurant
        self.isOrderIn = isOrderIn
        self.note = note
        self.createdAt = createdAt
        self.votedMemberIDs = votedMemberIDs ?? [proposedByMemberID]
    }

    var voteCount: Int { votedMemberIDs.count }

    func toggleVote(for memberID: UUID) {
        if let index = votedMemberIDs.firstIndex(of: memberID) {
            votedMemberIDs.remove(at: index)
        } else {
            votedMemberIDs.append(memberID)
        }
    }

    var displayTitle: String {
        recipe?.title ?? restaurant?.name ?? note ?? "Suggestion"
    }
}
