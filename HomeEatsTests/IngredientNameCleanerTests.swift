import XCTest
@testable import HomeEats

final class IngredientNameCleanerTests: XCTestCase {

    func testStripsParentheticalAside() {
        XCTAssertEqual(
            IngredientNameCleaner.groceryName(from: "brioche bread (Cut into thick slices)"),
            "brioche bread"
        )
    }

    func testStripsDoubledParentheticalWithNoOrphanCloseParen() {
        // Regression: a doubled/malformed parenthetical used to leave a
        // stray trailing ")" behind (e.g. "Brioche Bread )") since the old
        // regex only ever stripped one level.
        XCTAssertEqual(
            IngredientNameCleaner.groceryName(from: "brioche bread ((Cut into thick slices))"),
            "brioche bread"
        )
    }

    func testTrailingPrepInstructionAfterCommaIsStripped() {
        XCTAssertEqual(
            IngredientNameCleaner.groceryName(from: "onion, diced"),
            "onion"
        )
        XCTAssertEqual(
            IngredientNameCleaner.groceryName(from: "chicken breast, cut into thick slices"),
            "chicken breast"
        )
    }

    func testLeadingDescriptorsBeforeCommaAreKept() {
        // Regression: a comma separating two leading adjectives before the
        // noun used to get truncated down to just the first word.
        XCTAssertEqual(
            IngredientNameCleaner.groceryName(from: "skinless, boneless chicken thighs"),
            "skinless, boneless chicken thighs"
        )
    }

    func testToTasteSuffixIsStripped() {
        XCTAssertEqual(IngredientNameCleaner.groceryName(from: "salt, to taste"), "salt")
        XCTAssertEqual(IngredientNameCleaner.groceryName(from: "salt to taste"), "salt")
    }

    func testExcludesWaterAndIce() {
        XCTAssertTrue(IngredientNameCleaner.isExcludedFromGroceryList("water"))
        XCTAssertTrue(IngredientNameCleaner.isExcludedFromGroceryList("Ice"))
        XCTAssertFalse(IngredientNameCleaner.isExcludedFromGroceryList("coconut water"))
    }
}
