import SwiftData

/// The one place a `Recipe` actually gets deleted from — `RecipesHomeView`'s
/// swipe-to-delete and `RecipeEditorView`'s own "Delete Recipe" button (f22:
/// there was previously no way to delete a recipe from its own detail/edit
/// screen, only by finding it again in the list and swiping) both go through
/// this, so the "can't delete something still in a meal plan" rule and the
/// backend-sync behavior only exist in one place.
enum RecipeDeletion {
    enum Outcome {
        case deleted
        /// A human-readable reason the delete didn't happen — shown as a
        /// non-blocking alert by both call sites.
        case blocked(String)
    }

    /// Blocked outright if the recipe is still in the local, personal plan
    /// (see `CascadeCleanup`'s own doc comment). For a recipe that's also
    /// synced to the backend, this *waits* for the backend's own equivalent
    /// check — a recipe still decided into a *group's* shared plan — before
    /// committing the local delete, rather than firing that request in the
    /// background and deleting locally regardless of what it says (that
    /// used to be exactly how a recipe still in a group's plan ended up
    /// silently deleted out from under it, leaving that plan entry as a
    /// broken "Planned"/"by Someone" row — direct user report). A genuine
    /// connectivity failure (`AccountsAPIError` case other than `.server`,
    /// e.g. offline) still falls back to the previous offline-tolerant
    /// behavior — delete locally now, let the next opportunistic sync
    /// reconcile — since there's no way to know either way while offline,
    /// and blocking every delete just because the network happens to be
    /// down would be its own regression.
    @MainActor
    static func attempt(_ recipe: Recipe, in modelContext: ModelContext) async -> Outcome {
        guard !CascadeCleanup.isRecipeInAnyPlannedMeal(recipeID: recipe.id, in: modelContext) else {
            return .blocked("\"\(recipe.title)\" is in your meal plan. Remove it from the plan before deleting it.")
        }
        guard let backendRecipeID = recipe.backendRecipeID else {
            CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
            modelContext.delete(recipe)
            return .deleted
        }
        do {
            try await AccountsAPIClient.deleteRecipe(id: backendRecipeID)
            CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
            modelContext.delete(recipe)
            return .deleted
        } catch AccountsAPIError.server(let message) {
            return .blocked(message)
        } catch {
            CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
            modelContext.delete(recipe)
            return .deleted
        }
    }
}
