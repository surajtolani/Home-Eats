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
        // Filtered in Swift (via isSameDay) rather than a #Predicate on exact
        // Date equality: the rest of the app compares weeks the same way
        // (see GroceryListView), and comparing by exact instant instead would
        // silently stop matching after a timezone change, since the stored
        // "midnight" instant for a date no longer equals a freshly-computed
        // one — see `dedupedByCanonicalKey` below for what that used to cause.
        let allItems = (try? context.fetch(FetchDescriptor<GroceryItem>())) ?? []
        let existingItems = allItems.filter { $0.weekStartDate.isSameDay(as: normalizedWeekStart) }
        let existingThisWeek = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .thisWeek && !$0.isManuallyAdded },
            in: context
        )
        let existingStaples = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .staples },
            in: context
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
            if let existing = existingStaples[key] {
                // Pick up edits made in StaplesManagerView since this list
                // was last generated (category, usual amount) — checked
                // state is left alone since that's the user's in-store progress.
                existing.category = staple.category
                existing.quantityText = staple.defaultQuantityText ?? ""
            } else {
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

    /// Groups items by canonical key, keeping the first row for each key and
    /// deleting the rest. Building `[key: item]` with a plain
    /// `Dictionary(uniqueKeysWithValues:)` traps the whole app the moment two
    /// existing rows canonicalize to the same key (e.g. a seeded staple
    /// "Milk" plus a manually-added "milk", or two staples like "Eggs" and
    /// "Egg" that both exist and are both active) — this both avoids that
    /// crash and actually cleans up the duplicate rows that caused it, so it
    /// doesn't just re-trap on the next regenerate.
    private static func dedupedByCanonicalKey(
        _ items: [GroceryItem],
        in context: ModelContext
    ) -> [String: GroceryItem] {
        var result: [String: GroceryItem] = [:]
        for item in items {
            let key = canonicalKey(for: item.name)
            if result[key] != nil {
                context.delete(item)
            } else {
                result[key] = item
            }
        }
        return result
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
                // Canonicalize the unit before using it as a bucket key —
                // otherwise "1 cup" and "2 cups" land in separate buckets
                // ("cup" vs "cups") and never actually combine.
                let unitKey = ingredient.unit.map(IngredientLineParser.canonicalUnit) ?? ""
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
