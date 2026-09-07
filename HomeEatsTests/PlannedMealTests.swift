import XCTest
@testable import HomeEats

final class PlannedMealTests: XCTestCase {

    func testRestaurantMealDefaultsToEatingOutNotOrderIn() {
        let restaurant = Restaurant(name: "Local Diner")
        let meal = PlannedMeal(date: .now, slot: .dinner, restaurant: restaurant)
        XCTAssertTrue(meal.isEatingOut)
        XCTAssertFalse(meal.isOrderingIn)
    }

    /// Regression guard: eating out and ordering in must stay mutually
    /// exclusive for the same restaurant reference — this is the one flag
    /// the calendar's status dot and legend key off to pick a color.
    func testOrderInMealIsNotAlsoEatingOut() {
        let restaurant = Restaurant(name: "Local Diner")
        let meal = PlannedMeal(date: .now, slot: .dinner, restaurant: restaurant, isOrderIn: true)
        XCTAssertTrue(meal.isOrderingIn)
        XCTAssertFalse(meal.isEatingOut)
    }

    func testRecipeMealIsNeitherEatingOutNorOrderingIn() {
        let recipe = Recipe(title: "Tacos")
        let meal = PlannedMeal(date: .now, slot: .dinner, recipe: recipe)
        XCTAssertTrue(meal.isHomeCooked)
        XCTAssertFalse(meal.isEatingOut)
        XCTAssertFalse(meal.isOrderingIn)
    }
}
