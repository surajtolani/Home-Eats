import Foundation

/// Cleans up an ingredient's raw parsed name for use on the *grocery list*
/// specifically. `RecipeIngredientEntry.name`/`.displayText` keep the full
/// descriptive line ("onion, diced", "chicken breast, cut into thick
/// slices") since that's genuinely useful context while cooking from the
/// recipe itself — but that same text is clutter on a shopping list, where
/// you just want "onion". This only feeds grocery-list generation; the
/// recipe's own ingredient section is untouched.
enum IngredientNameCleaner {

    /// Trailing descriptive phrases that show up with or without a leading
    /// comma ("salt to taste", "salt, to taste") — stripped from the end of
    /// the name wherever they appear.
    private static let trailingPhrasePatterns: [String] = [
        #",?\s+to taste\.?$"#,
        #",?\s+for serving\.?$"#,
        #",?\s+for garnish\.?$"#,
        #",?\s+as needed\.?$"#,
        #",?\s+optional\.?$"#,
        #",?\s+if desired\.?$"#
    ]

    /// Ingredients that never belong on a shopping list — not real
    /// purchasable grocery items, just things every kitchen already has.
    /// Matched after cleaning + `GroceryListBuilder.canonicalKey`, so
    /// "Water", "water", and "waters" all match the same "water" entry —
    /// but "coconut water" or "rosewater" (genuinely purchasable products)
    /// deliberately don't, since this only matches the word on its own.
    private static let excludedNames: Set<String> = [
        "water", "cold water", "warm water", "hot water", "boiling water",
        "ice water", "tap water", "ice", "ice cube"
    ]

    /// Strips parenthetical asides and prep-instruction clauses, leaving
    /// just what you'd actually ask for at a store.
    static func groceryName(from rawName: String) -> String {
        var result = rawName

        // Parenthetical asides: "(to cook in)", "(optional)", "(for serving)".
        result = result.replacingOccurrences(
            of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression
        )

        // Everything after the first comma is almost always a prep
        // instruction ("diced", "cut into thick slices", "melted"), not
        // part of the ingredient itself.
        if let commaIndex = result.firstIndex(of: ",") {
            result = String(result[result.startIndex..<commaIndex])
        }

        // Catches the same phrases when they show up without a comma.
        for pattern in trailingPhrasePatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a (already-cleaned) grocery name is something that should
    /// never actually be added to the list.
    static func isExcludedFromGroceryList(_ cleanedName: String) -> Bool {
        excludedNames.contains(GroceryListBuilder.canonicalKey(for: cleanedName))
    }
}

extension String {
    /// Title Case for the short (1-4 word) ingredient/grocery item names
    /// shown in the recipe ingredient list and the grocery list — "ground
    /// beef" -> "Ground Beef". A display-only transform; the underlying
    /// stored value (used for canonical matching, which already
    /// case-folds) is never changed.
    var titleCasedForDisplay: String {
        capitalized
    }
}
