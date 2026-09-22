import SwiftData

/// The one place a `Restaurant` actually gets deleted from —
/// `RestaurantListView`'s swipe-to-delete and `RestaurantEditorView`'s own
/// "Delete Restaurant" button (f22: there was previously no way to delete a
/// restaurant from its own detail/edit screen, only by finding it again in
/// the list and swiping) both go through this, so the "can't delete
/// something still in a meal plan" rule and the backend-sync behavior only
/// exist in one place.
enum RestaurantDeletion {
    enum Outcome {
        case deleted
        /// A human-readable reason the delete didn't happen — shown as a
        /// non-blocking alert by both call sites.
        case blocked(String)
    }

    /// Blocked outright if the restaurant is still in the local, personal
    /// plan (see `CascadeCleanup`'s own doc comment). Unlike
    /// `RecipeDeletion.attempt`, the backend delete (when this restaurant
    /// has a `backendID`) fires and is not waited on — same "immediate,
    /// online-only" behavior `RestaurantListView`'s delete has always had,
    /// since a personal restaurant library has no group-shared-plan
    /// equivalent of the "still decided into a group's plan" case that
    /// makes `RecipeDeletion` wait on the backend first.
    @MainActor
    static func attempt(_ restaurant: Restaurant, in modelContext: ModelContext) -> Outcome {
        guard !CascadeCleanup.isRestaurantInAnyPlannedMeal(restaurantID: restaurant.id, in: modelContext) else {
            return .blocked("\"\(restaurant.name)\" is in your meal plan. Remove it from the plan before deleting it.")
        }
        CascadeCleanup.removeReferences(toRestaurantID: restaurant.id, in: modelContext)
        if let backendID = restaurant.backendID {
            Task { try? await AccountsAPIClient.deleteRestaurant(id: backendID) }
        }
        modelContext.delete(restaurant)
        return .deleted
    }
}
