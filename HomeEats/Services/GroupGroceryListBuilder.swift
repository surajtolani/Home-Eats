import Foundation
import SwiftData

/// Group-scoped counterpart of `GroceryListBuilder` — turns a chosen set of
/// planned-meal days into candidate grocery *suggestions*, the same
/// "Suggestions From Your Meal Plan" feature `GroceryListView` already has
/// for the personal planner (see that file's own `generateSuggestions`/
/// `suggestionDayStrip`), now working against `GroupPlannedMeal`/
/// `RemoteRecipe` instead of the personal `PlannedMeal`/`Recipe`. Restores
/// the "generate from recipes" gap a user flagged as missing from the group
/// grocery list.
///
/// **Where ingredients come from**: a `GroupPlannedMeal.recipeID` is just a
/// backend recipe-library id, and this app has no bulk "get these N
/// recipes' ingredients" endpoint, so each distinct recipe among the
/// selected days is fetched with `AccountsAPIClient.getRecipe(id:)` — the
/// exact same call `GroupSyncService.resolveRecipeTitle` already uses to
/// resolve a cached recipe title (see that method's own doc comment) — not
/// a second, separate resolution path. A meal with no `recipeID`
/// (restaurant/order-in) contributes nothing, matching
/// `GroceryListBuilder`'s own "restaurant days contribute nothing" rule. A
/// recipe fetch that fails (offline, deleted, no longer visible to the
/// caller) simply contributes nothing for that one recipe rather than
/// failing the whole generate — "best effort" matches this being a
/// convenience, not a page whose correctness anyone is blocked on.
///
/// **Aggregation and dedup reuse the personal builder's own pure helpers**
/// rather than reimplementing them: `GroceryListBuilder.canonicalKey(for:)`
/// for the case/plural-insensitive dedup key, `IngredientNameCleaner
/// .groceryName(from:)`/`.isExcludedFromGroceryList(_:)` to strip prep text
/// and skip non-purchasable ingredients (water, ice, ...), and
/// `IngredientLineParser.canonicalUnit(_:)`/`IngredientQuantityFormatter
/// .string(for:)` to combine/format quantities — all plain, model-agnostic
/// utilities with nothing personal-planner-specific about them, so reusing
/// them here doesn't touch `GroceryListView.swift`/`GroceryListBuilder.swift`
/// at all.
///
/// Unlike the personal `RecipeIngredientEntry`, a `RemoteIngredient` carries
/// no `category` of its own — `GroceryCategory.guess(fromIngredientName:)`
/// (the same best-effort guess `GroupSharedGroceryListView.quickAddField`
/// and the personal staples/add-item sheets already use) fills that in.
enum GroupGroceryListBuilder {

    /// One aggregated candidate line, keyed externally by
    /// `GroceryListBuilder.canonicalKey(for: displayName)` — pure, in-memory
    /// data with no network or `ModelContext` involved, so `aggregate(_:)`
    /// below is directly unit-testable on its own (see
    /// `GroupGroceryListBuilderTests`). `Hashable` (not just `Equatable`) so
    /// a batch of these can ride along on a SwiftUI `NavigationPath` —
    /// `GroupAddGroceriesFlow.swift`'s review screen is reached by pushing a
    /// `.reviewIngredients(candidates:)` destination carrying this array.
    struct Candidate: Equatable, Hashable {
        var displayName: String
        var category: GroceryCategory
        var quantityText: String
    }

    /// Pure aggregation: combines every ingredient across however many
    /// recipes contributed one, keyed by `GroceryListBuilder.canonicalKey`
    /// on its cleaned name — same "sum by canonical unit, join with ` + `,
    /// note the recipe count once there's more than one contributor" shape
    /// as the personal builder's own private `IngredientAggregate`, just
    /// operating on `RemoteIngredient` (backend wire shape) instead of the
    /// personal `RecipeIngredientEntry`.
    static func aggregate(ingredientsByRecipeID: [String: [RemoteIngredient]]) -> [String: Candidate] {
        var candidates: [String: Candidate] = [:]
        var totalsByKey: [String: [String: Double]] = [:]
        var recipeCountByKey: [String: Int] = [:]

        for (_, ingredients) in ingredientsByRecipeID {
            for ingredient in ingredients {
                let cleanName = IngredientNameCleaner.groceryName(from: ingredient.name)
                guard !cleanName.isEmpty, !IngredientNameCleaner.isExcludedFromGroceryList(cleanName) else {
                    continue
                }
                let key = GroceryListBuilder.canonicalKey(for: cleanName)

                if candidates[key] == nil {
                    candidates[key] = Candidate(
                        displayName: cleanName,
                        category: GroceryCategory.guess(fromIngredientName: cleanName),
                        quantityText: ""
                    )
                }
                recipeCountByKey[key, default: 0] += 1

                if let quantity = ingredient.quantity {
                    // Canonicalize the unit before using it as a bucket key
                    // — otherwise "1 cup" and "2 cups" land in separate
                    // buckets and never actually combine, same reasoning as
                    // the personal builder's identical step.
                    let unitKey = ingredient.unit.map(IngredientLineParser.canonicalUnit) ?? ""
                    totalsByKey[key, default: [:]][unitKey, default: 0] += quantity
                }
            }
        }

        for key in candidates.keys {
            var parts: [String] = []
            for (unit, total) in (totalsByKey[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let amount = IngredientQuantityFormatter.string(for: total)
                parts.append(unit.isEmpty ? amount : "\(amount) \(unit)")
            }
            let recipeCount = recipeCountByKey[key] ?? 0
            let suffix = recipeCount > 1 ? " (from \(recipeCount) recipes)" : ""
            candidates[key]?.quantityText = parts.isEmpty ? "" : parts.joined(separator: " + ") + suffix
        }
        return candidates
    }

    /// Same aggregation as `aggregate(ingredientsByRecipeID:)`, but over the
    /// personal `Recipe.ingredients` (`RecipeIngredientEntry`) instead of a
    /// backend `RemoteIngredient` — used by `GroupAddGroceriesFlow.swift`'s
    /// "From a Recipe" picker, which works directly off recipes already
    /// loaded locally via SwiftData rather than a planned meal's
    /// `recipeID` (so, unlike `resolveCandidates` below, there's no network
    /// fetch involved at all: a `Recipe` sitting in someone's own library
    /// already has everything needed). The one real difference from the
    /// remote version: `RecipeIngredientEntry` already carries its own
    /// `category` (set at import/entry time), so this uses that directly
    /// rather than falling back to `GroceryCategory.guess(fromIngredientName:)`
    /// the way a category-less `RemoteIngredient` has to.
    static func aggregateLocal(ingredientsByRecipeID: [UUID: [RecipeIngredientEntry]]) -> [String: Candidate] {
        var candidates: [String: Candidate] = [:]
        var totalsByKey: [String: [String: Double]] = [:]
        var recipeCountByKey: [String: Int] = [:]

        for (_, ingredients) in ingredientsByRecipeID {
            for ingredient in ingredients {
                let cleanName = IngredientNameCleaner.groceryName(from: ingredient.name)
                guard !cleanName.isEmpty, !IngredientNameCleaner.isExcludedFromGroceryList(cleanName) else {
                    continue
                }
                let key = GroceryListBuilder.canonicalKey(for: cleanName)

                if candidates[key] == nil {
                    candidates[key] = Candidate(displayName: cleanName, category: ingredient.category, quantityText: "")
                }
                recipeCountByKey[key, default: 0] += 1

                if let quantity = ingredient.quantity {
                    let unitKey = ingredient.unit.map(IngredientLineParser.canonicalUnit) ?? ""
                    totalsByKey[key, default: [:]][unitKey, default: 0] += quantity
                }
            }
        }

        for key in candidates.keys {
            var parts: [String] = []
            for (unit, total) in (totalsByKey[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let amount = IngredientQuantityFormatter.string(for: total)
                parts.append(unit.isEmpty ? amount : "\(amount) \(unit)")
            }
            let recipeCount = recipeCountByKey[key] ?? 0
            let suffix = recipeCount > 1 ? " (from \(recipeCount) recipes)" : ""
            candidates[key]?.quantityText = parts.isEmpty ? "" : parts.joined(separator: " + ") + suffix
        }
        return candidates
    }

    /// Local counterpart of `resolveCandidates` below, for the "From a
    /// Recipe" picker — same dedup-against-what's-already-on-the-list
    /// finishing step, just fed by `aggregateLocal` instead of a network
    /// fetch. `@MainActor` only because `existingItems` (SwiftData model
    /// objects) must be read on the main actor, same as `resolveCandidates`;
    /// there's no actual `await` inside this one.
    @MainActor
    static func resolveLocalCandidates(
        recipes: [Recipe],
        existingItems: [GroupSharedGroceryItem]
    ) -> [Candidate] {
        let ingredientsByRecipeID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.ingredients) })
        let candidates = aggregateLocal(ingredientsByRecipeID: ingredientsByRecipeID)
        let existingKeys = Set(existingItems.map { GroceryListBuilder.canonicalKey(for: $0.name) })
        return candidates
            .filter { !existingKeys.contains($0.key) }
            .map(\.value)
            .sorted { $0.displayName < $1.displayName }
    }

    /// Resolves whichever `plannedMeals` the caller already filtered down to
    /// the days/meals someone picked (mirroring `GroceryListBuilder
    /// .regenerate`'s own "filtering is the view's job, not the builder's"
    /// split) into aggregated candidate lines, excluding anything that
    /// canonically matches an item already on the list — matched case/
    /// plural-insensitively via the same canonical key, against every
    /// existing item regardless of section (mirroring `GroceryListBuilder
    /// .regenerate`'s own "the list is a single persistent whole" dedup
    /// against everything already there). Pure resolve-only: unlike this
    /// type's old `generate(...)` (removed — see `GroupAddGroceriesFlow
    /// .swift`'s `CookingListDaysView`/`ReviewIngredientsView` for what
    /// replaced it), this never touches a `ModelContext` or inserts
    /// anything itself. The caller now always gets a chance to review and
    /// check off which candidates it actually wants before anything is
    /// created — `generate(...)` used to skip straight to inserting every
    /// candidate as an unreviewed `.suggested` row, which is what made a
    /// separate manager-review step necessary there; the dedicated review
    /// screen this feeds now serves that same purpose up front, so a
    /// reviewed pick can go straight onto the real list for a MANAGER, the
    /// same as any other direct add (see `ReviewIngredientsView.commit()`'s
    /// own doc comment for the fuller reasoning, mirroring the role split
    /// every other add path on this screen already uses).
    @MainActor
    static func resolveCandidates(
        plannedMeals: [GroupPlannedMeal],
        existingItems: [GroupSharedGroceryItem]
    ) async -> [Candidate] {
        let recipeIDs = Set(plannedMeals.compactMap(\.recipeID))
        guard !recipeIDs.isEmpty else { return [] }

        var ingredientsByRecipeID: [String: [RemoteIngredient]] = [:]
        for recipeID in recipeIDs {
            if let recipe = try? await AccountsAPIClient.getRecipe(id: recipeID) {
                ingredientsByRecipeID[recipeID] = recipe.ingredients
            }
        }

        let candidates = aggregate(ingredientsByRecipeID: ingredientsByRecipeID)
        let existingKeys = Set(existingItems.map { GroceryListBuilder.canonicalKey(for: $0.name) })
        return candidates
            .filter { !existingKeys.contains($0.key) }
            .map(\.value)
            .sorted { $0.displayName < $1.displayName }
    }
}
