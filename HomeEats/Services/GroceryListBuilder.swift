import Foundation
import SwiftData

/// Builds/refreshes the grocery list's *suggestions*: pulls ingredients from
/// whichever planned meals the caller passes in (typically whatever date
/// range someone picked in "Suggestions From Your Meal Plan"), merges
/// duplicates into one line each, and surfaces anything new as a pending
/// suggestion — never directly onto the visible list. Restaurant days
/// contribute nothing (per spec, only home-cooked recipes need groceries).
/// `staples` is accepted for callers that still want to merge in active
/// household staples the same way, but nothing in the app currently does —
/// "Generate Suggestions" deliberately passes `[]` so a short/empty
/// meal-plan result reads as "nothing needed," not as a wall of unrelated
/// staples (see GroceryListView.generateSuggestions).
///
/// The grocery list itself is a single persistent, standing list — not
/// scoped to any particular week — so this always merges against
/// *everything* already on it, regardless of when it was added.
/// `plannedMeals` is what makes a given call about a particular stretch of
/// the meal plan: pass an empty array to just refresh staples without
/// pulling in any recipe ingredients.
enum GroceryListBuilder {

    /// Regenerates grocery *suggestions* inside `context` from
    /// `plannedMeals` and any active staple passed in. This never adds
    /// anything directly to the visible list — a brand new ingredient or
    /// staple always lands in `.suggested`, pending an explicit Add/Reject;
    /// only a key already decided (accepted, or legacy `.staples`) gets
    /// refreshed in place. Rejecting a suggestion deletes it outright (see
    /// GroceryListView.reject) rather than parking it in some remembered
    /// "rejected" state, so there's nothing to refresh-in-place for a
    /// rejection — the next time that ingredient shows up in a planned
    /// meal, it's indistinguishable from one never suggested before.
    /// Existing checked state, manual additions, and chosen product options
    /// for items that persist are preserved; a pending suggestion that's no
    /// longer needed (a recipe was swapped out of the range, or a staple
    /// deactivated) is removed — anything already decided is never
    /// auto-removed this way.
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
                // `groceryNames` (plural) — almost always one name, but a
                // known combined line like "salt and pepper" contributes to
                // *both* the "salt" and "pepper" buckets separately, same
                // as if the recipe had listed them as two lines to begin
                // with — see that function's own doc comment.
                for cleanName in IngredientNameCleaner.groceryNames(from: ingredient.name) {
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
        // Household Groceries entries with a noted brand/product, keyed by
        // canonical name — used below to carry that preference straight
        // onto any brand-new suggested line this generates. Direct user
        // request: "is there a way to have it where if you add something...
        // from a grocery list generated from the recipes, it prompts you to
        // ask if you want to add the additional details from your household
        // grocery list?" — a prompt PER generated ingredient would mean one
        // alert after another for what's often a dozen-plus lines at once,
        // so this applies the preference silently instead: the person still
        // sees and can change it (the product thumbnail on the resulting
        // row), it just doesn't gate every single generated line behind its
        // own confirmation.
        let preferredProductByKey: [String: UUID] = (try? context.fetch(FetchDescriptor<HistoricalGroceryItem>()))
            .map { historicalItems in
                // `uniquingKeysWith:` (keep the first), not
                // `uniqueKeysWithValues:` — two Household Groceries rows can
                // canonicalize to the same key in practice (bulk paste-import
                // only dedupes within its own batch, never against what's
                // already in the catalog — see `GroceryHistoryImportSheet
                // .importItems`), which would otherwise crash this lookup.
                Dictionary(
                    historicalItems.compactMap { historyItem in
                        historyItem.preferredProductOptionID.map { (canonicalKey(for: historyItem.name), $0) }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            } ?? [:]
        let existingSuggested = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .suggested },
            in: context
        )
        let existingThisWeek = dedupedByCanonicalKey(
            existingItems.filter { $0.section == .thisWeek && !$0.isManuallyAdded },
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
                item.selectedProductOptionID = preferredProductByKey[key]
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

    /// Normalizes an ingredient/staple name so simple plurals, casing, word
    /// order, and modifier placement don't produce duplicate lines for what
    /// is really the same purchasable item — direct user question: recipes
    /// phrase the same ingredient different ways ("chicken thighs, cut up"
    /// vs. "thighs chicken," "minced garlic" vs. "garlic minced"), and
    /// those used to land as two separate grocery list lines instead of
    /// one combined quantity, since nothing normalized word order or a
    /// modifier's position in the phrase.
    ///
    /// Splits into words first and singularizes/filters/sorts each one
    /// individually, rather than the simpler "just singularize the whole
    /// joined string's own trailing suffix" this used to do — that only
    /// ever singularized whichever word happened to land last, which
    /// itself depends on word order: "chicken thighs" (trailing word
    /// "thighs" -> "thigh") and "thighs chicken" (trailing word "chicken,"
    /// never touching "thighs" at all) would otherwise still end up as two
    /// different keys ("chicken thigh" vs. "chicken thighs") even after
    /// sorting, defeating the whole point of normalizing word order in the
    /// first place.

    /// Nouns whose product identity actually changes depending on which
    /// modifier is attached — "diced tomatoes" is a specific canned SKU,
    /// not a prep instruction for fresh "tomatoes"; "crushed red pepper" is
    /// a spice-rack item, not a prep instruction for a fresh "red pepper."
    /// For these nouns only, the modifiers below are kept as part of the
    /// key instead of being stripped like an ordinary prep verb, so the two
    /// don't collide. Deliberately narrow (two nouns) rather than a general
    /// "some modifiers are product-defining" rule, which would need a much
    /// larger, harder-to-get-right list to avoid new false merges elsewhere.
    ///
    /// Known, accepted scoping limitation: this checks whether a
    /// product-defining noun appears ANYWHERE in the phrase, not whether it
    /// sits next to the modifier — so a hypothetical multi-ingredient name
    /// like "diced onion and tomato" would wrongly keep "diced" attached
    /// even though it modifies "onion," not "tomato." Left as-is rather
    /// than adding adjacency logic, since a cleaned grocery name is always
    /// one `RecipeIngredientEntry.name`, i.e. already a single ingredient
    /// by construction — this multi-noun shape essentially doesn't occur.
    private static let productDefiningNouns: Set<String> = ["tomato", "pepper"]
    private static let productDefiningModifierWords: Set<String> = [
        "diced", "crushed", "stewed", "pureed", "puree"
    ]

    /// A deliberately NARROWER subset of `IngredientLineParser.knownUnits`:
    /// only words that are always a discrete sub-part of a single food
    /// item, never the terminal noun of a standalone product name.
    /// Red-team-verified false merges from using the *full* `knownUnits`
    /// set here instead: "fish sticks" -> "fish" (collided with plain
    /// "fish"), "chocolate bar"/"granola bar" -> "chocolate"/"granola",
    /// "bottle gourd" (a real, distinct vegetable) -> "gourd". Words like
    /// bar/stick/bag/box/bottle/jar/can/package/container/packet/envelope/
    /// loaf are container- or product-shape words that legitimately show
    /// up as the last word of a real product name, so they're excluded
    /// here even though they're valid *units* for
    /// `IngredientLineParser`'s own quantity-parsing purposes.
    private static let trailingCountNounUnits: Set<String> = [
        "clove", "cloves", "slice", "slices", "head", "heads",
        "sprig", "sprigs", "stalk", "stalks", "piece", "pieces",
        "pinch", "pinches", "dash", "dashes", "bunch", "bunches"
    ]

    static func canonicalKey(for rawName: String) -> String {
        // Fold accents so "jalapeño" and "jalapeno" merge instead of
        // landing as two separate grocery-list lines just because one
        // recipe site used the accented spelling and another didn't.
        var trimmed = rawName
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenIndex = trimmed.firstIndex(of: "(") {
            trimmed = String(trimmed[trimmed.startIndex..<parenIndex]).trimmingCharacters(in: .whitespaces)
        }
        // A comma is treated as a plain word boundary here too, in case
        // this raw name never went through `IngredientNameCleaner
        // .groceryName`'s own trailing-comma-clause handling first.
        let rawWords = trimmed
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        let hasProductDefiningNoun = rawWords.contains {
            productDefiningNouns.contains(singularizedWord($0))
        }
        let words = rawWords
            .filter { word in
                if hasProductDefiningNoun, productDefiningModifierWords.contains(word) {
                    return true
                }
                return !IngredientNameCleaner.modifierWords.contains(word)
                    && !trailingCountNounUnits.contains(word)
            }
            .map(singularizedWord)
            .sorted()
        return words.isEmpty ? trimmed : words.joined(separator: " ")
    }

    /// Same simple plural-suffix rules this method always used, just
    /// applied to one word at a time instead of only the trailing word of
    /// a whole joined string — see `canonicalKey`'s own doc comment for
    /// why that distinction matters once word order is being normalized
    /// too.
    private static func singularizedWord(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"
        } else if word.hasSuffix("oes"), word.count > 4 {
            return String(word.dropLast(2))
        } else if word.hasSuffix("es"), word.count > 4, word.hasSuffix("shes") || word.hasSuffix("ches") || word.hasSuffix("xes") {
            return String(word.dropLast(2))
        } else if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 {
            return String(word.dropLast())
        }
        return word
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
