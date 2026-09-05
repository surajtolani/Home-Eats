import XCTest
import SwiftData
@testable import HomeEats

@MainActor
final class GroceryListBuilderTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            FamilyMember.self, Recipe.self, Restaurant.self, DayPlan.self,
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

        let monday = DayPlan(date: .now)
        monday.finalize(recipe: tacoNight, by: nil)
        let tuesday = DayPlan(date: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
        tuesday.finalize(recipe: chiliNight, by: nil)
        context.insert(monday)
        context.insert(tuesday)

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(
            weekStart: weekStart,
            dayPlans: [monday, tuesday],
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

    func testRestaurantDaysContributeNoIngredients() throws {
        let context = try makeInMemoryContext()
        let restaurant = Restaurant(name: "Local Diner")
        context.insert(restaurant)
        let dayPlan = DayPlan(date: .now)
        dayPlan.finalize(restaurant: restaurant, by: nil)
        context.insert(dayPlan)

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(weekStart: weekStart, dayPlans: [dayPlan], staples: [], in: context)

        let items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.filter { $0.section == .thisWeek }.isEmpty)
    }

    func testActiveStaplesAreIncludedAndInactiveAreRemoved() throws {
        let context = try makeInMemoryContext()
        let milk = StapleItem(name: "Milk", category: .dairyAndEggs, isActive: true)
        context.insert(milk)

        let weekStart = Calendar.current.startOfWeek(containing: .now)
        GroceryListBuilder.regenerate(weekStart: weekStart, dayPlans: [], staples: [milk], in: context)

        var items = try context.fetch(FetchDescriptor<GroceryItem>())
        XCTAssertTrue(items.contains { $0.name == "Milk" && $0.section == .staples })

        milk.isActive = false
        GroceryListBuilder.regenerate(weekStart: weekStart, dayPlans: [], staples: [milk], in: context)
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
