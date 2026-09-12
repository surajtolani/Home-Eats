import Foundation
import SwiftData

/// Builds/refreshes the grocery list's *suggestions*: pulls ingredients from
/// whichever planned meals the caller passes in (typically whatever date
/// range someone picked in "Suggestions From Your Meal Plan") plus every
/// active household staple, merges duplicates into one line each, and
/// surfaces anything new as a pending suggestion — never directly onto the
/// visible list. Restaurant days contribute nothing (per spec, only
/// home-cooked recipes need groceries).
///
/// The grocery list itself is a single persistent, standing list — not
/// scoped to any particular week — so this always merges against
/// *everything* already on it, regardless of when it was added.
/// `plannedMeals` is what makes a given call about a particular stretch of
/// the meal plan: pass an empty array to just refresh staples without
/// pulling in any recipe ingredients.
enum GroceryListBuilder {

    /// Regenerates grocery *suggestions* inside `context` from
    /// `plannedMeals` and every active staple. This never adds anything
    /// directly to the visible list — a brand new ingredient or staple
    /// always lands in `.suggested`, pending an explicit Add/Reject; only a
    /// key already decided (accepted, legacy `.staples`, or rejected) gets
    /// refreshed in place. Existing checked state, manual additions, and
    /// chosen product options for items that persist are preserved; a
    /// pending suggestion that's no longer needed (a recipe was swapped
    /// out of the range, or a staple deactivated) is removed — anything
    /// already decided is never auto-removed this way.
    @MainActor
    static func regenerate(
        plannedMeals: [PlannedMeal],
        staples: [StapleItem],
        in context: ModelContext
    ) {
        // 1. Aggregate ingredients across every home-cooked meal passed in
        // (any slot — breakfast, lunch, dinner, or other all count).
        let recipes = plannedMeals.compactMap(\.recipe)

        var aggregates: [String: IngredientAggregate] = [:]
        for recipe in recipes {
            for ingredient in recipe.ingredients {
                // Strip prep instructions ("onion, diced" -> "onion") before
                // this ever becomes a grocery line — the recipe's own
                // ingredient list keeps the full descriptive text, but a
                // shopping list should just say what to buy. Ingredients
                // that aren't actually purchasable at all (water, ice) are
                // skipped entirely rather than becoming a line item.
                let cleanName = IngredientNameCleaner.groceryName(from: ingredient.name)
                guard !cleanName.isEmpty, !IngredientNameCleaner.isExcludedFromGroceryList(cleanName) else {
                    continue
                }
                let key = canonicalKey(for: cleanName)
                var aggregate = aggregates[key] ?? IngredientAggregate(
                    displayName: cleanName,
                    category: ingredient.category
                )
                aggregate.add(ingredient, from: recipe.id)
                aggregates[key] = aggregate
            }
        }

        // Active staples feed into this exact same aggregate set now,
        // rather than being inserted straight onto the visible list —
        // nothing should land there without a chance to Add/Reject it
        // first, staples included. A staple whose name also matches a
        // recipe ingredient needed this week (e.g. "milk" for a recipe,
        // and kept as a standing staple) merges into that same line
        // instead of becoming a second one.
        for staple in staples where staple.isActive {
            let key = canonicalKey(for: staple.name)
            var aggregate = aggregates[key] ?? IngredientAggregate(
                displayName: staple.name,
                category: staple.category
            )
            aggregate.addStaple(staple)
            aggregates[key] = aggregate
        }

        // 2. Fetch every existing item so we can preserve user state — the
        // whole persistent list, not scoped to any particular week.
        let existingItems = (try? context.fetch(FetchDescriptor<GroceryItem>())) ?? []
        let existingSuggested = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .suggested },
            in: context
        )
        let existingThisWeek = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .thisWeek && !$0.isManuallyAdded },
            in: context
        )
        let existingRejected = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .rejected },
            in: context
        )
        let existingStaples = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .staples },
            in: context
        )

        // Newly-created lines are appended after everything that already
        // exists on the list (rather than, say, starting back at 0), so a
        // manual reorder never gets disturbed by a regenerate picking up a
        // new ingredient partway through the list.
        var nextOrderIndex = (existingItems.map(\.orderIndex).max() ?? 0) + 1

        // 3. Upsert every candidate line — recipe ingredients and active
        // staples alike, now that both flow through the same pipeline. A
        // key already decided (accepted onto the list — either
        // `.thisWeek`, or a legacy `.staples` row from before staples
        // required review — or explicitly rejected) is refreshed in place
        // but never moved back to "suggested": regenerating is meant to
        // pick up ingredient/quantity changes, not re-litigate a decision
        // already made. A brand new key becomes a fresh suggestion,
        // pending Add/Reject — nothing is ever inserted directly onto the
        // visible list by this function.
        var seenKeys = Set<String>()
        for (key, aggregate) in aggregates {
            seenKeys.insert(key)
            if let existing = existingThisWeek[key] {
                refresh(existing, from: aggregate)
            } else if let existing = existingStaples[key] {
                refresh(existing, from: aggregate)
            } else if let existing = existingRejected[key] {
                refresh(existing, from: aggregate)
            } else if let existing = existingSuggested[key] {
                refresh(existing, from: aggregate)
            } else {
                let item = GroceryItem(
                    name: aggregate.displayName,
                    category: aggregate.category,
                    section: .suggested,
                    quantityText: aggregate.quantityText,
                    sourceRecipeIDs: Array(aggregate.recipeIDs),
                    orderIndex: nextOrderIndex
                )
                nextOrderIndex += 1
                context.insert(item)
            }
        }
        // Remove pending suggestions whose *staple* is no longer needed (it
        // was deactivated before ever being decided on) — but never a
        // recipe-derived one just because this particular call's
        // `plannedMeals` didn't include it. A call is often scoped to just
        // one chosen date range now that the list is persistent rather than
        // regenerated wholesale for "this week" every time, so a key
        // missing from *this* aggregate no longer means "no longer on the
        // plan anywhere" — only a suggestion with no recipe behind it at
        // all (`sourceRecipeIDs` empty, i.e. purely staple-derived) can
        // safely be inferred stale from its absence here. Accepted/rejected
        // lines are never auto-removed this way regardless — once the user
        // has decided on something, only they remove it (the quantity
        // stepper's trash icon).
        for (key, item) in existingSuggested where !seenKeys.contains(key) && item.sourceRecipeIDs.isEmpty {
            context.delete(item)
        }
        // Legacy `.staples` rows (accepted before staples required review)
        // are grandfathered in place — deactivating that staple still
        // removes it, matching the old behavior for anything not yet
        // migrated into the unified suggested/accepted pipeline above.
        for (key, item) in existingStaples where !seenKeys.contains(key) && !item.isManuallyAdded {
            context.delete(item)
        }
    }

    /// Refreshes an existing recipe-derived line's quantity/provenance from
    /// a newly-computed aggregate. Category is skipped if the user has
    /// since dragged the item to a different category themselves.
    private static func refresh(_ item: GroceryItem, from aggregate: IngredientAggregate) {
        item.quantityText = aggregate.quantityText
        item.sourceRecipeIDs = Array(aggregate.recipeIDs)
        if !item.categoryManuallySet {
            item.category = aggregate.category
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
        var recipeIDs: Set<UUID> = []
        /// Set when a staple contributes to this line — a staple's amount
        /// is just a plain user-entered description ("1 gallon"), not a
        /// parsed unit total, so it's kept separately and appended as-is
        /// rather than folded into `totalsByUnit`.
        var stapleQuantityText: String?

        mutating func add(_ ingredient: RecipeIngredientEntry, from recipeID: UUID) {
            recipeIDs.insert(recipeID)
            guard let quantity = ingredient.quantity else { return }
            // Canonicalize the unit before using it as a bucket key —
            // otherwise "1 cup" and "2 cups" land in separate buckets
            // ("cup" vs "cups") and never actually combine.
            let unitKey = ingredient.unit.map(IngredientLineParser.canonicalUnit) ?? ""
            totalsByUnit[unitKey, default: 0] += quantity
        }

        mutating func addStaple(_ staple: StapleItem) {
            guard stapleQuantityText == nil, let text = staple.defaultQuantityText, !text.isEmpty else { return }
            stapleQuantityText = text
        }

        var quantityText: String {
            var parts: [String] = []
            for (unit, total) in totalsByUnit.sorted(by: { $0.key < $1.key }) {
                let amount = IngredientQuantityFormatter.string(for: total)
                parts.append(unit.isEmpty ? amount : "\(amount) \(unit)")
            }
            if let stapleQuantityText {
                parts.append(stapleQuantityText)
            }
            // No numeric quantity was ever parsed for this ingredient (e.g.
            // "salt to taste") — nothing to show here rather than falling
            // back to the raw, unclean source line.
            let recipeSuffix = recipeIDs.count > 1 ? " (from \(recipeIDs.count) recipes)" : ""
            return parts.isEmpty ? "" : parts.joined(separator: " + ") + recipeSuffix
        }
    }
}
