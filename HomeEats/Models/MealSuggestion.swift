import Foundation
import SwiftData

/// A proposal from one family member for what a given day's meal should be,
/// plus a lightweight up-vote list so other members can weigh in without
/// building a full poll/comment system.
@Model
final class MealSuggestion {
    @Attribute(.unique) var id: UUID
    var dayPlan: DayPlan?
    var proposedByMemberID: UUID
    var recipe: Recipe?
    var restaurant: Restaurant?
    var note: String?
    var createdAt: Date
    /// IDs of family members who upvoted this suggestion (proposer included by default).
    var votedMemberIDs: [UUID]

    init(
        id: UUID = UUID(),
        proposedByMemberID: UUID,
        recipe: Recipe? = nil,
        restaurant: Restaurant? = nil,
        note: String? = nil,
        createdAt: Date = .now,
        votedMemberIDs: [UUID]? = nil
    ) {
        self.id = id
        self.proposedByMemberID = proposedByMemberID
        self.recipe = recipe
        self.restaurant = restaurant
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
