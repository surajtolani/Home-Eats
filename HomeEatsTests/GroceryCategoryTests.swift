import XCTest
@testable import HomeEats

final class GroceryCategoryTests: XCTestCase {

    /// Regression test: "dish" used to match as a bare substring inside
    /// "radishes", miscategorizing a vegetable as a household item.
    func testRadishesIsProduceNotHousehold() {
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "radishes"), .produce)
    }

    /// Regression test: "water" used to match as a bare substring inside
    /// "watermelon", miscategorizing a fruit as a beverage.
    func testWatermelonIsProduceNotBeverages() {
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "watermelon"), .produce)
    }

    /// Regression test: produce's bare "pepper" keyword used to be checked
    /// before pantry's specific "pepper flakes" phrase, so a spice always
    /// lost to the vegetable category.
    func testPepperFlakesIsPantryNotProduce() {
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "pepper flakes"), .pantry)
    }

    func testFreshPepperIsStillProduce() {
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "bell pepper"), .produce)
    }

    func testPluralIngredientMatchesSingularKeyword() {
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "onions"), .produce)
        XCTAssertEqual(GroceryCategory.guess(fromIngredientName: "tomatoes"), .produce)
    }
}
