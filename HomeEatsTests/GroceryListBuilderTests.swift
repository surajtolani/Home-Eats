import XCTest
import SwiftData
@testable import HomeEats

@MainActor
final class GroceryListBuilderTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            FamilyMember.self, Recipe.self, Restaurant.self, PlannedMeal.self,
            MealSuggestion.self, GroceryItem.self, ProductOption.self,
            StapleItem.self, MealHistoryEntry.self, AppSettings.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return container.mainContext
    }

    func testCombinesDuplicateIngredientsAcrossRecipes() throws {
        let context = try makeInMemoryContext()

        let tacoNight = Recipe(
            title: "Tacos",
            ingredients: [
                RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup"),
                RecipeIngredientEntry(name: "ground beef", quantity: 1, unit: "lb")
            ]
        )
        let chiliNight = Recipe(
            title: "Chili",
            ingredients: [
                RecipeIngredientEntry(name: "onions", quantity: 2, unit: "cup"),
                RecipeIngredientEntry(name: "kidney beans", quantity: 1, unit: "can")
            ]
        )
        context.insert(tacoNight)
        context.insert(chiliNight)

        let monday = PlannedMeal(date: .now, slot: .dinner, recipe: tacoNight)
        let tuesday = PlannedMeal(
            date: Calendar.current.date(byAdding: .day, value: 1, to: .now)!,
            slot: .dinner,
            recipe: chiliNight
        )
        context.insert(monday)
        context.insert(tuesday)

        GroceryListBuilder.regenerate(
            plannedMeals: [monday, tuesday],
            staples: [],
            in: context
        )

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItem = items.first { $0.name.lowercased().contains("onion") }
        XCTAssertNotNil(onionItem, "Expected a merged onion line item")
        XCTAssertEqual(onionItem?.quantityText.contains("3"), true, "1 cup + 2 cups should combine to 3 cups")
        XCTAssertEqual(onionItem?.category, .produce)
        XCTAssertEqual(onionItem?.sourceRecipeIDs.count, 2)

        let beefItem = items.first { $0.name.lowercased().contains("beef") }
        XCTAssertEqual(beefItem?.category, .meatAndSeafood)
    }

    func testRestaurantMealsContributeNoIngredients() throws {
        let context = try makeInMemoryContext()
        let restaurant = Restaurant(name: "Local Diner")
        context.insert(restaurant)
        let meal = PlannedMeal(date: .now, slot: .dinner, restaurant: restaurant)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.filter { $0.section == .thisWeek }.isEmpty)
    }

    func testMultipleSlotsOnSameDayAllContributeIngredients() throws {
        let context = try makeInMemoryContext()
        let pancakes = Recipe(title: "Pancakes", ingredients: [
            RecipeIngredientEntry(name: "flour", quantity: 2, unit: "cups")
        ])
        let tacos = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "tortillas", quantity: 8, unit: nil)
        ])
        context.insert(pancakes)
        context.insert(tacos)

        let breakfast = PlannedMeal(date: .now, slot: .breakfast, recipe: pancakes)
        let dinner = PlannedMeal(date: .now, slot: .dinner, recipe: tacos)
        context.insert(breakfast)
        context.insert(dinner)

        GroceryListBuilder.regenerate(
            plannedMeals: [breakfast, dinner],
            staples: [],
            in: context
        )

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name.lowercased().contains("flour") })
        XCTAssertTrue(items.contains { $0.name.lowercased().contains("tortilla") })
    }

    func testActiveStaplesAreIncludedAndInactiveAreRemoved() throws {
        let context = try makeInMemoryContext()
        let milk = StapleItem(name: "Milk", category: .dairyAndEggs, isActive: true)
        context.insert(milk)

        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        // A staple is now a pending suggestion, same as a recipe ingredient
        // — never inserted straight onto the list.
        XCTAssertTrue(items.contains { $0.name == "Milk" && $0.section == .suggested })

        milk.isActive = false
        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)
        items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertFalse(items.contains { $0.name == "Milk" })
    }

    /// The explicit point of this whole design: regenerating should never
    /// put a staple directly onto the visible list — only ever into
    /// Suggested, pending Add/Reject, exactly like a recipe ingredient.
    func testStaplesNeverLandDirectlyOnTheList() throws {
        let context = try makeInMemoryContext()
        let paperTowels = StapleItem(name: "Paper Towels", category: .household, isActive: true)
        context.insert(paperTowels)

        GroceryListBuilder.regenerate(plannedMeals: [], staples: [paperTowels], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertFalse(items.contains { $0.name == "Paper Towels" && $0.section == .thisWeek })
        XCTAssertFalse(items.contains { $0.name == "Paper Towels" && $0.section == .staples })
        XCTAssertTrue(items.contains { $0.name == "Paper Towels" && $0.section == .suggested })
    }

    /// Once a staple suggestion has been accepted (moved to `.thisWeek`),
    /// deactivating the staple shouldn't yank it back off the list —
    /// consistent with how an accepted recipe ingredient is never
    /// auto-removed once decided.
    func testAcceptedStapleSurvivesDeactivation() throws {
        let context = try makeInMemoryContext()
        let milk = StapleItem(name: "Milk", category: .dairyAndEggs, isActive: true)
        context.insert(milk)

        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        let suggestion = try XCTUnwrap(items.first { $0.name == "Milk" })
        suggestion.section = .thisWeek // simulate tapping "Add"

        milk.isActive = false
        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name == "Milk" && $0.section == .thisWeek })
    }

    /// A staple whose name also matches a recipe ingredient needed this
    /// week should merge into that one line rather than becoming a
    /// duplicate second suggestion.
    func testStapleMergesWithMatchingRecipeIngredient() throws {
        let context = try makeInMemoryContext()
        let recipe = Recipe(title: "Pancakes", ingredients: [
            RecipeIngredientEntry(name: "milk", quantity: 1, unit: "cup")
        ])
        context.insert(recipe)
        let meal = PlannedMeal(date: .now, slot: .breakfast, recipe: recipe)
        context.insert(meal)
        let milk = StapleItem(name: "Milk", category: .dairyAndEggs, isActive: true)
        context.insert(milk)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [milk], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let milkItems = items.filter { $0.name.lowercased() == "milk" }
        XCTAssertEqual(milkItems.count, 1, "Should merge into a single suggested line, not two")
        XCTAssertEqual(milkItems.first?.section, .suggested)
    }

    /// Regression test for a real crash: two staples that canonicalize to
    /// the same key (e.g. "Egg" and "Eggs") used to make `regenerate` build
    /// its lookup dictionary with `Dictionary(uniqueKeysWithValues:)`, which
    /// traps on a duplicate key. It shouldn't just avoid crashing — it
    /// should also actually clean up the duplicate so the *next* regenerate
    /// doesn't hit the same problem again.
    func testDuplicateCanonicalStapleNamesDoNotCrash() throws {
        let context = try makeInMemoryContext()
        let egg = StapleItem(name: "Egg", category: .dairyAndEggs, isActive: true)
        let eggs = StapleItem(name: "Eggs", category: .dairyAndEggs, isActive: true)
        context.insert(egg)
        context.insert(eggs)

        // Both staples are active on the very first regenerate, so the
        // upsert loop itself creates the duplicate pair of GroceryItems
        // that then collide the next time around.
        GroceryListBuilder.regenerate(plannedMeals: [], staples: [egg, eggs], in: context)
        GroceryListBuilder.regenerate(plannedMeals: [], staples: [egg, eggs], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let eggItems = items.filter { GroceryListBuilder.canonicalKey(for: $0.name) == "egg" }
        XCTAssertEqual(eggItems.count, 1, "Duplicate canonical-key rows should have been cleaned up to one")
    }

    /// Regression test: "1 cup" + "2 cups" used to land in separate
    /// unit buckets ("cup" vs "cups") and never actually combine.
    func testCombinesIngredientsWhoseUnitsAreSingularVsPlural() throws {
        let context = try makeInMemoryContext()
        let recipeA = Recipe(title: "A", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        let recipeB = Recipe(title: "B", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 2, unit: "cups")
        ])
        context.insert(recipeA)
        context.insert(recipeB)
        let mealA = PlannedMeal(date: .now, slot: .dinner, recipe: recipeA)
        let mealB = PlannedMeal(date: .now, slot: .lunch, recipe: recipeB)
        context.insert(mealA)
        context.insert(mealB)

        GroceryListBuilder.regenerate(plannedMeals: [mealA, mealB], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItem = items.first { $0.name.lowercased().contains("onion") }
        XCTAssertEqual(onionItem?.quantityText, "3 cups (from 2 recipes)")
    }

    /// Recipe ingredients should land in `.suggested`, pending an Add/Reject
    /// decision, rather than going straight onto the list — the whole point
    /// being to let a week where you already have half the ingredients on
    /// hand skip re-buying them.
    func testRecipeIngredientsLandInSuggestedNotThisWeek() throws {
        let context = try makeInMemoryContext()
        let tacoNight = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        context.insert(tacoNight)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: tacoNight)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItem = items.first { $0.name.lowercased().contains("onion") }
        XCTAssertEqual(onionItem?.section, .suggested)
        XCTAssertTrue(items.filter { $0.section == .thisWeek }.isEmpty)
    }

    /// The list is a single persistent, standing list now — a call is often
    /// scoped to just one chosen date range rather than "everything on the
    /// plan," so a pending suggestion from an earlier call must not get
    /// deleted just because a *later* call's `plannedMeals` (a different
    /// range) doesn't happen to include it too.
    func testRecipeDerivedSuggestionSurvivesARegenerateForADifferentRange() throws {
        let context = try makeInMemoryContext()
        let tacoNight = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        let pancakes = Recipe(title: "Pancakes", ingredients: [
            RecipeIngredientEntry(name: "flour", quantity: 2, unit: "cups")
        ])
        context.insert(tacoNight)
        context.insert(pancakes)
        let mealThisWeek = PlannedMeal(date: .now, slot: .dinner, recipe: tacoNight)
        let mealNextWeek = PlannedMeal(
            date: Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            slot: .breakfast,
            recipe: pancakes
        )
        context.insert(mealThisWeek)
        context.insert(mealNextWeek)

        // First call only covers this week's meal.
        GroceryListBuilder.regenerate(plannedMeals: [mealThisWeek], staples: [], in: context)
        // A later call for a different range (next week) shouldn't know or
        // care about the onion suggestion from the first call.
        GroceryListBuilder.regenerate(plannedMeals: [mealNextWeek], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name.lowercased().contains("onion") && $0.section == .suggested })
        XCTAssertTrue(items.contains { $0.name.lowercased().contains("flour") && $0.section == .suggested })
    }

    /// Once a suggestion has been accepted (moved to `.thisWeek`, as the
    /// "Add" button does), regenerating the list again shouldn't move it
    /// back to `.suggested` or duplicate it — the decision already made
    /// should stick, only its quantity/provenance should refresh.
    func testAcceptedSuggestionSurvivesRegenerateWithoutReverting() throws {
        let context = try makeInMemoryContext()
        let tacoNight = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        context.insert(tacoNight)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: tacoNight)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        let suggestion = try XCTUnwrap(items.first { $0.name.lowercased().contains("onion") })
        suggestion.section = .thisWeek // simulate tapping "Add"

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItems = items.filter { $0.name.lowercased().contains("onion") }
        XCTAssertEqual(onionItems.count, 1, "Should not duplicate into a second suggested row")
        XCTAssertEqual(onionItems.first?.section, .thisWeek)
    }

    /// Rejecting a suggestion ("I already have this") deletes it outright
    /// (see GroceryListView.reject) rather than parking it in some
    /// remembered "rejected" state — so the same ingredient needed by a
    /// *different* planned meal later must come back as a brand new
    /// suggestion, indistinguishable from one never seen before. This used
    /// to regress: `.rejected` rows were treated as an already-made
    /// decision and just refreshed in place, silently blocking that
    /// ingredient from ever being suggested again for any future meal.
    func testRejectingADeletedSuggestionComesBackForALaterMeal() throws {
        let context = try makeInMemoryContext()
        let tacoNight = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        context.insert(tacoNight)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: tacoNight)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        let suggestion = try XCTUnwrap(items.first { $0.name.lowercased().contains("onion") })
        context.delete(suggestion) // simulate tapping "Reject"

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.filter { $0.name.lowercased().contains("onion") }.isEmpty)

        // A different day's meal also calls for onion.
        let fajitaNight = Recipe(title: "Fajitas", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        context.insert(fajitaNight)
        let laterMeal = PlannedMeal(date: .now.addingTimeInterval(86400), slot: .dinner, recipe: fajitaNight)
        context.insert(laterMeal)

        GroceryListBuilder.regenerate(plannedMeals: [meal, laterMeal], staples: [], in: context)

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItems = items.filter { $0.name.lowercased().contains("onion") }
        XCTAssertEqual(onionItems.count, 1, "Rejecting once shouldn't permanently block this ingredient")
        XCTAssertEqual(onionItems.first?.section, .suggested, "Should come back as a fresh suggestion, not stay rejected")
    }

    /// A category the user drags to a new spot (`categoryManuallySet`)
    /// should never be silently reset by the next regenerate — mirrors how
    /// a "My Layout" aisle placement is never auto-overwritten.
    func testManuallySetCategorySurvivesRegenerate() throws {
        let context = try makeInMemoryContext()
        let milk = StapleItem(name: "Milk", category: .dairyAndEggs, isActive: true)
        context.insert(milk)

        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        let milkItem = try XCTUnwrap(items.first { $0.name == "Milk" })
        milkItem.category = .pantry // simulate a drag to a different category
        milkItem.categoryManuallySet = true

        GroceryListBuilder.regenerate(plannedMeals: [], staples: [milk], in: context)

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertEqual(items.first { $0.name == "Milk" }?.category, .pantry)
    }

    /// Freshly generated items should each get a distinct, increasing
    /// `orderIndex` — not all default to 0, which would leave their
    /// relative order within a category undefined.
    func testNewItemsGetIncreasingOrderIndex() throws {
        let context = try makeInMemoryContext()
        let recipe = Recipe(title: "Salad", ingredients: [
            RecipeIngredientEntry(name: "lettuce", quantity: 1, unit: nil),
            RecipeIngredientEntry(name: "tomato", quantity: 1, unit: nil),
            RecipeIngredientEntry(name: "cucumber", quantity: 1, unit: nil)
        ])
        context.insert(recipe)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: recipe)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let orderIndices = Set(items.map(\.orderIndex))
        XCTAssertEqual(orderIndices.count, items.count, "Every item should get its own distinct orderIndex")
    }

    /// A manual reorder (dragging one item in front of another, setting
    /// `orderIndex` directly) should never be reset by a later regenerate —
    /// same guarantee as `categoryManuallySet` above, for position instead
    /// of category.
    func testManualOrderIndexSurvivesRegenerate() throws {
        let context = try makeInMemoryContext()
        let recipe = Recipe(title: "Salad", ingredients: [
            RecipeIngredientEntry(name: "lettuce", quantity: 1, unit: nil),
            RecipeIngredientEntry(name: "tomato", quantity: 1, unit: nil)
        ])
        context.insert(recipe)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: recipe)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        let lettuce = try XCTUnwrap(items.first { $0.name.lowercased().contains("lettuce") })
        let tomato = try XCTUnwrap(items.first { $0.name.lowercased().contains("tomato") })
        // Simulate dragging tomato in front of lettuce.
        tomato.orderIndex = lettuce.orderIndex - 1

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        items = try context.fetch(FetchDescriptor<GroceryItem>())
        let refreshedLettuce = try XCTUnwrap(items.first { $0.name.lowercased().contains("lettuce") })
        let refreshedTomato = try XCTUnwrap(items.first { $0.name.lowercased().contains("tomato") })
        XCTAssertLessThan(refreshedTomato.orderIndex, refreshedLettuce.orderIndex)
    }

    /// Recipe ingredient names carry prep instructions ("onion, diced") the
    /// recipe view wants but a shopping list doesn't — those should be
    /// stripped by the time an ingredient becomes a `GroceryItem`.
    func testStripsPrepInstructionsFromGroceryItemNames() throws {
        let context = try makeInMemoryContext()
        let recipe = Recipe(title: "Tacos", ingredients: [
            RecipeIngredientEntry(name: "onion, diced", quantity: 1, unit: nil),
            RecipeIngredientEntry(name: "chicken breast, cut into thick slices", quantity: 1, unit: "lb"),
            RecipeIngredientEntry(name: "olive oil (to cook in)", quantity: 1, unit: "tbsp")
        ])
        context.insert(recipe)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: recipe)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name == "onion" })
        XCTAssertTrue(items.contains { $0.name == "chicken breast" })
        XCTAssertTrue(items.contains { $0.name == "olive oil" })
        XCTAssertFalse(items.contains { $0.name.contains(",") })
        XCTAssertFalse(items.contains { $0.name.contains("(") })
    }

    /// A recipe-derived "onion, diced" and a staple "onion" should still
    /// merge into a single grocery line despite the prep-instruction suffix
    /// on the recipe's copy.
    func testCleanedNameStillMergesWithPlainDuplicate() throws {
        let context = try makeInMemoryContext()
        let recipeA = Recipe(title: "A", ingredients: [
            RecipeIngredientEntry(name: "onion, diced", quantity: 1, unit: "cup")
        ])
        let recipeB = Recipe(title: "B", ingredients: [
            RecipeIngredientEntry(name: "onion", quantity: 1, unit: "cup")
        ])
        context.insert(recipeA)
        context.insert(recipeB)
        let mealA = PlannedMeal(date: .now, slot: .dinner, recipe: recipeA)
        let mealB = PlannedMeal(date: .now, slot: .lunch, recipe: recipeB)
        context.insert(mealA)
        context.insert(mealB)

        GroceryListBuilder.regenerate(plannedMeals: [mealA, mealB], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItems = items.filter { $0.name.lowercased() == "onion" }
        XCTAssertEqual(onionItems.count, 1, "Should merge into a single line, not two separate ones")
        XCTAssertEqual(onionItems.first?.quantityText, "2 cups (from 2 recipes)")
    }

    /// "Water" isn't a real purchasable grocery item — it should never make
    /// it onto the generated list at all.
    func testWaterIsExcludedFromGroceryList() throws {
        let context = try makeInMemoryContext()
        let recipe = Recipe(title: "Pasta", ingredients: [
            RecipeIngredientEntry(name: "water", quantity: 4, unit: "cups"),
            RecipeIngredientEntry(name: "spaghetti", quantity: 1, unit: "lb")
        ])
        context.insert(recipe)
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: recipe)
        context.insert(meal)

        GroceryListBuilder.regenerate(plannedMeals: [meal], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertFalse(items.contains { $0.name.lowercased().contains("water") })
        XCTAssertTrue(items.contains { $0.name.lowercased().contains("spaghetti") })
    }

    func testCanonicalKeyMergesSimplePlurals() {
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: "Onions"),
            GroceryListBuilder.canonicalKey(for: "onion")
        )
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: "Tomatoes"),
            GroceryListBuilder.canonicalKey(for: "tomato")
        )
    }

    /// Direct user question: two recipes phrasing the same ingredient in a
    /// different word order used to land as two separate grocery list
    /// lines. See `GroceryListBuilder.canonicalKey`'s own doc comment.
    func testCanonicalKeyMergesReorderedWords() {
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: "chicken thighs, cut up"),
            GroceryListBuilder.canonicalKey(for: "thighs chicken")
        )
    }

    /// Same fix, for a modifier word leading the phrase instead of a
    /// trailing comma clause.
    func testCanonicalKeyMergesLeadingAndTrailingModifiers() {
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: "minced garlic"),
            GroceryListBuilder.canonicalKey(for: "garlic minced")
        )
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: "minced garlic"),
            GroceryListBuilder.canonicalKey(for: "garlic, minced")
        )
    }
}
