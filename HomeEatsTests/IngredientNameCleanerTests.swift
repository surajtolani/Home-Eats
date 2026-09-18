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

    /// Direct, confirmed report: "water for rice" (and its comma variant)
    /// was showing up as its own grocery item instead of being recognized
    /// as plain, non-purchasable water.
    func testWaterForPurposeIsExcluded() {
        XCTAssertTrue(
            IngredientNameCleaner.isExcludedFromGroceryList(IngredientNameCleaner.groceryName(from: "water for rice"))
        )
        XCTAssertTrue(
            IngredientNameCleaner.isExcludedFromGroceryList(IngredientNameCleaner.groceryName(from: "water, for cooking rice"))
        )
        // A genuinely purchasable ingredient with its own "for ..." purpose
        // note should still just have the note stripped, not itself be
        // excluded.
        XCTAssertEqual(IngredientNameCleaner.groceryName(from: "olive oil for frying"), "olive oil")
    }

    /// Direct, confirmed report: "grated ginger" and "grated fresh ginger"
    /// were landing as two separate grocery lines.
    func testFreshIsStrippedAsAModifier() {
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: IngredientNameCleaner.groceryName(from: "grated ginger")),
            GroceryListBuilder.canonicalKey(for: IngredientNameCleaner.groceryName(from: "grated fresh ginger"))
        )
    }

    /// Direct, confirmed report: "lemon juice" and "3 tablespoons of lemon
    /// juice" were landing as two separate grocery lines — a raw ingredient
    /// line whose quantity/unit never got split out at all (so "3
    /// tablespoons of lemon juice" sat whole in the name) still needs to
    /// canonically match a cleanly-parsed "lemon juice" from another recipe.
    func testEmbeddedLeadingQuantityAndUnitAreStripped() {
        XCTAssertEqual(IngredientNameCleaner.groceryName(from: "3 tablespoons of lemon juice"), "lemon juice")
        XCTAssertEqual(
            GroceryListBuilder.canonicalKey(for: IngredientNameCleaner.groceryName(from: "lemon juice")),
            GroceryListBuilder.canonicalKey(for: IngredientNameCleaner.groceryName(from: "3 tablespoons of lemon juice"))
        )
        // A bare leading number that isn't a real measurement (no
        // recognized unit right after it) must be left alone — this isn't
        // a general "strip any leading digits" rule.
        XCTAssertEqual(IngredientNameCleaner.groceryName(from: "2% milk"), "2% milk")
    }

    /// Direct, confirmed report: "salt", "salt and pepper", and "salt +
    /// pepper" were all landing as separate, unmerged lines instead of
    /// "salt and pepper" contributing to the same "salt"/"pepper" entries
    /// any other recipe's plain "salt"/"pepper" lines already use.
    func testSaltAndPepperSplitsIntoTwoIngredients() {
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "salt and pepper"), ["salt", "pepper"])
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "salt + pepper"), ["salt", "pepper"])
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "Salt & Pepper"), ["salt", "pepper"])
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "salt and pepper, to taste"), ["salt", "pepper"])
        // Not a general "split on and" rule — a real single-ingredient name
        // that happens to contain "and" must come back untouched.
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "mac and cheese"), ["mac and cheese"])
        // An ordinary ingredient with nothing to split still comes back as
        // a single-element array.
        XCTAssertEqual(IngredientNameCleaner.groceryNames(from: "onion"), ["onion"])
    }
}
