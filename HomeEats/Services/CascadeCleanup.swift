import Foundation
import SwiftData

/// `PlannedMeal.recipe`/`.restaurant` and `MealSuggestion.recipe`/`.restaurant`
/// are plain optional references with no declared inverse relationship or
/// delete rule, so SwiftData won't clean them up on its own when a `Recipe`
/// or `Restaurant` is deleted — the plan and any suggestions just silently
/// point at nothing (`displayTitle` falls through to "Planned"/"Suggestion"
/// with no way to tell what it used to be). Call these *before* deleting the
/// recipe/restaurant so the plan stays honest about what's actually left.
@MainActor
enum CascadeCleanup {
    static func removeReferences(toRecipeID recipeID: UUID, in context: ModelContext) {
        let meals = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        for meal in meals where meal.recipe?.id == recipeID {
            context.delete(meal)
        }
        let suggestions = (try? context.fetch(FetchDescriptor<MealSuggestion>())) ?? []
        for suggestion in suggestions where suggestion.recipe?.id == recipeID {
            context.delete(suggestion)
        }
    }

    static func removeReferences(toRestaurantID restaurantID: UUID, in context: ModelContext) {
        let meals = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        for meal in meals where meal.restaurant?.id == restaurantID {
            context.delete(meal)
        }
        let suggestions = (try? context.fetch(FetchDescriptor<MealSuggestion>())) ?? []
        for suggestion in suggestions where suggestion.restaurant?.id == restaurantID {
            context.delete(suggestion)
        }
    }

    /// `FamilyMember` is referenced everywhere by raw `UUID` (not a
    /// relationship), so deleting one leaves `decidedByMemberID`,
    /// `proposedByMemberID`, and any vote in `votedMemberIDs` pointing at a
    /// person who no longer exists — those rows just lose their attribution
    /// badge, which is harmless, *except* a vote that can never be removed
    /// again (the UI can only toggle the *active* member's own vote) and a
    /// suggestion's vote count staying permanently inflated by one ghost
    /// vote. This strips the deleted member out of every vote list instead.
    static func removeVotes(fromMemberID memberID: UUID, in context: ModelContext) {
        let suggestions = (try? context.fetch(FetchDescriptor<MealSuggestion>())) ?? []
        for suggestion in suggestions where suggestion.votedMemberIDs.contains(memberID) {
            suggestion.votedMemberIDs.removeAll { $0 == memberID }
        }
    }
}
