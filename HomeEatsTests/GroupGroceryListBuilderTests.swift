import XCTest
@testable import HomeEats

/// Unit tests for `GroupGroceryListBuilder.aggregate(ingredientsByRecipeID:)`
/// — the pure, in-memory half of the group-scoped "generate suggestions
/// from your meal plan" feature (see that type's own doc comment). Deliberately
/// only covers `aggregate(_:)`, not the network/`ModelContext`-touching
/// `generate(...)` wrapper around it — same "test the pure logic directly,
/// no live server or SwiftData store needed" reasoning as
/// `GroupSyncReconciliationTests`'s coverage of `ReconciliationAction.decide`.
final class GroupGroceryListBuilderTests: XCTestCase {

    private func ingredient(_ name: String, quantity: Double? = nil, unit: String? = nil) -> RemoteIngredient {
        RemoteIngredient(id: UUID().uuidString, name: name, quantity: quantity, unit: unit)
    }

    func testCombinesDuplicateIngredientsAcrossRecipesByCanonicalKey() {
        // "onion" (Tacos) and "onions" (Chili) must merge into one line,
        // same case/plural-insensitive dedup as the personal
        // `GroceryListBuilder.canonicalKey`.
        let candidates = GroupGroceryListBuilder.aggregate(ingredientsByRecipeID: [
            "tacos": [ingredient("onion", quantity: 1, unit: "cup"), ingredient("ground beef", quantity: 1, unit: "lb")],
            "chili": [ingredient("onions", quantity: 2, unit: "cups"), ingredient("kidney beans", quantity: 1, unit: "can")]
        ])

        let onionKey = GroceryListBuilder.canonicalKey(for: "onion")
        let onion = candidates[onionKey]
        XCTAssertNotNil(onion, "Expected a merged onion line item")
        XCTAssertEqual(onion?.category, .produce)
        XCTAssertTrue(onion?.quantityText.contains("3") ?? false, "1 cup + 2 cups should combine to 3 cups")
        XCTAssertTrue(onion?.quantityText.contains("from 2 recipes") ?? false)

        let beefKey = GroceryListBuilder.canonicalKey(for: "ground beef")
        XCTAssertEqual(candidates[beefKey]?.category, .meatAndSeafood)
        // Only one recipe contributed beef — no "(from N recipes)" suffix.
        XCTAssertFalse(candidates[beefKey]?.quantityText.contains("recipes") ?? true)
    }

    func testExcludedIngredientsContributeNoCandidate() {
        // "water" is on `IngredientNameCleaner`'s never-add-to-the-list set
        // — same rule the personal builder applies.
        let candidates = GroupGroceryListBuilder.aggregate(ingredientsByRecipeID: [
            "soup": [ingredient("water", quantity: 4, unit: "cups"), ingredient("carrot", quantity: 2)]
        ])
        XCTAssertNil(candidates[GroceryListBuilder.canonicalKey(for: "water")])
        XCTAssertNotNil(candidates[GroceryListBuilder.canonicalKey(for: "carrot")])
    }

    func testIngredientWithNoQuantityStillProducesACandidateWithEmptyQuantityText() {
        // "salt to taste" style lines: no numeric quantity was ever parsed,
        // but the ingredient itself is still real and should still show up
        // as a candidate — just with nothing to show for its amount.
        let candidates = GroupGroceryListBuilder.aggregate(ingredientsByRecipeID: [
            "stew": [ingredient("salt")]
        ])
        let salt = candidates[GroceryListBuilder.canonicalKey(for: "salt")]
        XCTAssertNotNil(salt)
        XCTAssertEqual(salt?.quantityText, "")
    }

    func testPrepInstructionsAreStrippedFromTheDisplayName() {
        // "chicken breast, diced" -> "chicken breast" — same trailing-prep
        // stripping `IngredientNameCleaner.groceryName(from:)` already does
        // for the personal builder, reused here rather than reimplemented.
        let candidates = GroupGroceryListBuilder.aggregate(ingredientsByRecipeID: [
            "stirfry": [ingredient("chicken breast, diced", quantity: 1, unit: "lb")]
        ])
        let chicken = candidates[GroceryListBuilder.canonicalKey(for: "chicken breast")]
        XCTAssertEqual(chicken?.displayName, "chicken breast")
    }

    func testNoRecipesProducesNoCandidates() {
        XCTAssertTrue(GroupGroceryListBuilder.aggregate(ingredientsByRecipeID: [:]).isEmpty)
    }
}
