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
    /// `GroupGroceryListBuilderTests`).
    struct Candidate: Equatable {
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

    /// Orchestrates the full "generate suggestions for these days" action:
    /// takes whichever `plannedMeals` the caller already filtered down to
    /// the days someone picked (mirroring `GroceryListBuilder.regenerate`'s
    /// own "filtering is the view's job, not the builder's" split), resolves
    /// each distinct recipe's ingredients from the backend, aggregates them,
    /// and inserts a `.pendingCreate` `.suggested` `GroupSharedGroceryItem`
    /// for every candidate not already present on the group's list — matched
    /// case/plural-insensitively via the same canonical key, against every
    /// existing item regardless of section (mirroring
    /// `GroceryListBuilder.regenerate`'s own "the list is a single
    /// persistent whole" dedup against everything already there, not just
    /// what's already suggested). Existing items are never modified — a
    /// repeat "Generate" for an overlapping set of days simply skips
    /// whatever's already on the list instead of creating a duplicate
    /// suggestion. New items always land as `.suggested`, open to either
    /// role: generating a suggestion isn't a "decide" action any more than a
    /// PARTICIPANT's own manual suggestion is — a MANAGER still has to
    /// accept it onto the real list, same as any other suggestion.
    ///
    /// - Returns: how many new suggestions were actually inserted, for a
    ///   caller that wants to show something (not currently surfaced by
    ///   `GroupSharedGroceryListView`, which — matching the personal
    ///   screen's own silent-insert behavior — just lets the newly-created
    ///   rows appear in the "Suggested" list below rather than popping a
    ///   separate confirmation).
    @MainActor
    static func generate(
        groupID: String,
        plannedMeals: [GroupPlannedMeal],
        existingItems: [GroupSharedGroceryItem],
        currentUserID: String,
        modelContext: ModelContext
    ) async -> Int {
        let recipeIDs = Set(plannedMeals.compactMap(\.recipeID))
        guard !recipeIDs.isEmpty else { return 0 }

        var ingredientsByRecipeID: [String: [RemoteIngredient]] = [:]
        for recipeID in recipeIDs {
            if let recipe = try? await AccountsAPIClient.getRecipe(id: recipeID) {
                ingredientsByRecipeID[recipeID] = recipe.ingredients
            }
        }

        let candidates = aggregate(ingredientsByRecipeID: ingredientsByRecipeID)
        let existingKeys = Set(existingItems.map { GroceryListBuilder.canonicalKey(for: $0.name) })

        var addedCount = 0
        for (key, candidate) in candidates where !existingKeys.contains(key) {
            let item = GroupSharedGroceryItem(
                id: GroupSharedGroceryItem.newLocalPlaceholderID(),
                groupID: groupID,
                name: candidate.displayName,
                category: candidate.category,
                section: .suggested,
                quantityText: candidate.quantityText,
                addedByUserID: currentUserID,
                syncState: .pendingCreate
            )
            modelContext.insert(item)
            addedCount += 1
        }
        if addedCount > 0 {
            try? modelContext.save()
        }
        return addedCount
    }
}
