import Foundation
import SwiftData

/// `PlannedMeal.recipe`/`.restaurant` and `MealSuggestion.recipe`/`.restaurant`
/// are plain optional references with no declared inverse relationship or
/// delete rule, so SwiftData won't clean them up on its own when a `Recipe`
/// or `Restaurant` is deleted.
///
/// Direct, pointed user report of exactly this: a recipe that was still
/// decided into a shared group's plan got deleted, and that plan entry
/// silently turned into a broken-looking "Planned" / "by Someone" row with
/// no way to tell what it used to be — "should never delete a recipe... if
/// it's already in a plan." `isRecipeInAnyPlannedMeal`/
/// `isRestaurantInAnyPlannedMeal` below are the guard every recipe/
/// restaurant delete flow now checks *first*: if either is true, the
/// delete is refused outright (the caller shows an alert instead) rather
/// than silently orphaning the plan the way it used to. A `MealSuggestion`
/// is only a proposed candidate, not yet "in the plan" the way a decided
/// `PlannedMeal` is, so it's still fine to quietly clean those up —
/// `removeReferences` below still does exactly that, just without also
/// deleting `PlannedMeal` rows anymore, since a delete that would need to
/// touch one of those never reaches this function at all now.
@MainActor
enum CascadeCleanup {
    static func isRecipeInAnyPlannedMeal(recipeID: UUID, in context: ModelContext) -> Bool {
        let meals = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        return meals.contains { $0.recipe?.id == recipeID }
    }

    static func isRestaurantInAnyPlannedMeal(restaurantID: UUID, in context: ModelContext) -> Bool {
        let meals = (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? []
        return meals.contains { $0.restaurant?.id == restaurantID }
    }

    static func removeReferences(toRecipeID recipeID: UUID, in context: ModelContext) {
        let suggestions = (try? context.fetch(FetchDescriptor<MealSuggestion>())) ?? []
        for suggestion in suggestions where suggestion.recipe?.id == recipeID {
            context.delete(suggestion)
        }
    }

    static func removeReferences(toRestaurantID restaurantID: UUID, in context: ModelContext) {
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
