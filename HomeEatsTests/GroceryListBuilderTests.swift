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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(
            weekStart: weekStart,
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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [meal], staples: [], in: context)

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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(
            weekStart: weekStart,
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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [], staples: [milk], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name == "Milk" && $0.section == .staples })

        milk.isActive = false
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [], staples: [milk], in: context)
        items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertFalse(items.contains { $0.name == "Milk" })
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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        // Both staples are active on the very first regenerate, so the
        // upsert loop itself creates the duplicate pair of GroceryItems
        // that then collide the next time around.
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [], staples: [egg, eggs], in: context)
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [], staples: [egg, eggs], in: context)

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

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(weekStart: weekStart, plannedMeals: [mealA, mealB], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        let onionItem = items.first { $0.name.lowercased().contains("onion") }
        XCTAssertEqual(onionItem?.quantityText, "3 cups (from 2 recipes)")
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
}
