import Foundation
import SwiftData

/// Builds/refreshes the grocery list for a given week: pulls ingredients from
/// every home-cooked day in that week, merges duplicate ingredients into one
/// line, sorts everything by store category, and appends the household's
/// standing "staples" section. Restaurant days contribute nothing (per spec,
/// only home-cooked recipes need groceries).
enum GroceryListBuilder {

    /// Regenerates the "this week" + "staples" grocery items for `weekStart`
    /// inside `context`. Existing checked state, manual additions, and chosen
    /// product options for items that persist are preserved; items that no
    /// longer apply (e.g. a recipe was swapped out) are removed unless the
    /// user added them manually.
    @MainActor
    static func regenerate(
        weekStart: Date,
        plannedMeals: [PlannedMeal],
        staples: [StapleItem],
        in context: ModelContext
    ) {
        let normalizedWeekStart = Calendar.current.startOfDay(for: weekStart)

        // 1. Aggregate ingredients across every home-cooked meal this week
        // (any slot — breakfast, lunch, dinner, or other all count).
        let recipes = plannedMeals.compactMap(\.recipe)

        var aggregates: [String: IngredientAggregate] = [:]
        for recipe in recipes {
            for ingredient in recipe.ingredients {
                let key = canonicalKey(for: ingredient.name)
                var aggregate = aggregates[key] ?? IngredientAggregate(
                    displayName: ingredient.name,
                    category: ingredient.category
                )
                aggregate.add(ingredient, from: recipe.id)
                aggregates[key] = aggregate
            }
        }

        // 2. Fetch existing items for this week so we can preserve user state.
        let weekStartCopy = normalizedWeekStart
        let descriptor = FetchDescriptor<GroceryItem>(
            predicate: #Predicate { $0.weekStartDate == weekStartCopy }
        )
        let existingItems = (try? context.fetch(descriptor)) ?? []
        let existingThisWeek = Dictionary(
            uniqueKeysWithValues: existingItems
                .filter { $0.section == .thisWeek && !$0.isManuallyAdded }
                .map { (canonicalKey(for: $0.name), $0) }
        )
        let existingStaples = Dictionary(
            uniqueKeysWithValues: existingItems
                .filter { $0.section == .staples }
                .map { (canonicalKey(for: $0.name), $0) }
        )

        // 3. Upsert "this week" lines.
        var seenKeys = Set<String>()
        for (key, aggregate) in aggregates {
            seenKeys.insert(key)
            if let existing = existingThisWeek[key] {
                existing.quantityText = aggregate.quantityText
                existing.category = aggregate.category
                existing.sourceRecipeIDs = Array(aggregate.recipeIDs)
            } else {
                let item = GroceryItem(
                    name: aggregate.displayName,
                    category: aggregate.category,
                    section: .thisWeek,
                    quantityText: aggregate.quantityText,
                    weekStartDate: normalizedWeekStart,
                    sourceRecipeIDs: Array(aggregate.recipeIDs)
                )
                context.insert(item)
            }
        }
        // Remove auto-generated lines whose ingredient is no longer needed.
        for (key, item) in existingThisWeek where !seenKeys.contains(key) {
            context.delete(item)
        }

        // 4. Upsert staples lines (only active ones).
        var seenStapleKeys = Set<String>()
        for staple in staples where staple.isActive {
            let key = canonicalKey(for: staple.name)
            seenStapleKeys.insert(key)
            if existingStaples[key] == nil {
                let item = GroceryItem(
                    name: staple.name,
                    category: staple.category,
                    section: .staples,
                    quantityText: staple.defaultQuantityText ?? "",
                    weekStartDate: normalizedWeekStart
                )
                context.insert(item)
            }
        }
        // Remove staple lines for staples the user has since deactivated
        // (but never touch manual additions).
        for (key, item) in existingStaples where !seenStapleKeys.contains(key) && !item.isManuallyAdded {
            context.delete(item)
        }
    }

    /// Normalizes an ingredient/staple name so simple plurals and casing
    /// don't produce duplicate lines (e.g. "onion" and "Onions").
    static func canonicalKey(for rawName: String) -> String {
        var key = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenIndex = key.firstIndex(of: "(") {
            key = String(key[key.startIndex..<parenIndex]).trimmingCharacters(in: .whitespaces)
        }
        if key.hasSuffix("ies"), key.count > 4 {
            key = String(key.dropLast(3)) + "y"
        } else if key.hasSuffix("oes"), key.count > 4 {
            key = String(key.dropLast(2))
        } else if key.hasSuffix("es"), key.count > 4, key.hasSuffix("shes") || key.hasSuffix("ches") || key.hasSuffix("xes") {
            key = String(key.dropLast(2))
        } else if key.hasSuffix("s"), !key.hasSuffix("ss"), key.count > 3 {
            key = String(key.dropLast())
        }
        return key
    }

    private struct IngredientAggregate {
        var displayName: String
        var category: GroceryCategory
        var totalsByUnit: [String: Double] = [:]
        var freeTextParts: [String] = []
        var recipeIDs: Set<UUID> = []

        mutating func add(_ ingredient: RecipeIngredientEntry, from recipeID: UUID) {
            recipeIDs.insert(recipeID)
            if let quantity = ingredient.quantity {
                let unitKey = (ingredient.unit ?? "").lowercased()
                totalsByUnit[unitKey, default: 0] += quantity
            } else if !ingredient.rawText.isEmpty {
                freeTextParts.append(ingredient.rawText)
            }
        }

        var quantityText: String {
            var parts: [String] = []
            for (unit, total) in totalsByUnit.sorted(by: { $0.key < $1.key }) {
                let amount = IngredientQuantityFormatter.string(for: total)
                parts.append(unit.isEmpty ? amount : "\(amount) \(unit)")
            }
            parts.append(contentsOf: freeTextParts)
            let recipeSuffix = recipeIDs.count > 1 ? " (from \(recipeIDs.count) recipes)" : ""
            return parts.isEmpty ? "" : parts.joined(separator: " + ") + recipeSuffix
        }
    }
}
