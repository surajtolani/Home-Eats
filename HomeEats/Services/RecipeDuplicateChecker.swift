import Foundation

/// Duplicate-detection for recipes — direct user request: "Recipes...
/// should not be able to be added twice." Checked right before inserting a
/// genuinely new recipe from every add flow that can produce one
/// (`RecipeEditorView`'s manual entry, `RecipeImportView`'s URL import,
/// `RecipeAIImportView`'s photo/notes import) so each one can offer the
/// same "Add Anyway?" confirmation instead of silently creating a second
/// copy. **Not** used by `RecipesHomeView.saveSharedRecipe`/
/// `saveLibraryEntry` — a Shared/Library save already dedupes reliably via
/// `Recipe.backendRecipeID` (the exact same backend row, not just a
/// probably-the-same-recipe guess), a stronger signal than anything this
/// title/URL heuristic can offer.
enum RecipeDuplicateChecker {
    /// The one existing recipe this would duplicate, if any — checked
    /// against the account's own recipes only (mirrors `RecipesHomeView
    /// .myRecipes`'s own filter: a bundled `.library` recipe nobody has
    /// saved to their collection isn't "already added," so it's excluded
    /// here the same way). An exact, non-empty `sourceURL` match is
    /// checked first — the strongest signal, since importing the exact
    /// same page twice really is the same recipe, whatever its title says
    /// — falling back to a case-insensitive, trimmed title match
    /// otherwise (the only signal a manual or AI-photo entry has at all,
    /// neither of which carries a `sourceURL`).
    static func existingMatch(title: String, sourceURL: String?, in recipes: [Recipe]) -> Recipe? {
        let myRecipes = recipes.filter { $0.source != .library || $0.isSavedToCollection }
        if let sourceURL, !sourceURL.isEmpty,
           let match = myRecipes.first(where: { $0.sourceURL == sourceURL }) {
            return match
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return nil }
        return myRecipes.first { $0.title.caseInsensitiveCompare(trimmedTitle) == .orderedSame }
    }
}
