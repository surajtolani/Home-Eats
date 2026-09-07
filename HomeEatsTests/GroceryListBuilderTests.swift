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
