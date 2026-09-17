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

    /// Prep/action words — reused two ways: right after a comma here, they
    /// mean everything from there on is a trailing instruction to cut
    /// ("chicken breast, diced" -> "chicken breast") rather than part of
    /// the ingredient name itself (a comma can just as easily separate two
    /// leading descriptors instead, "skinless, boneless chicken thighs" —
    /// only cutting when the text right after the comma actually starts
    /// with one of these is what keeps that case intact instead of
    /// truncating down to "Skinless"). Also reused by `GroceryListBuilder
    /// .canonicalKey`, which strips these from *anywhere* in the name (not
    /// just right after a comma) before matching — see that method's own
    /// doc comment for why a leading modifier ("minced garlic" vs. "garlic
    /// minced") needs the same treatment as a trailing one for two
    /// differently-worded lines to actually merge on the grocery list.
    static let modifierWords: Set<String> = [
        "diced", "sliced", "chopped", "minced", "peeled", "seeded", "crushed",
        "grated", "melted", "softened", "beaten", "drained", "rinsed",
        "shredded", "julienned", "cubed", "halved", "quartered", "trimmed",
        "cut", "zested", "juiced", "mashed", "toasted", "roasted", "cooked",
        "divided", "packed", "sifted", "washed", "patted", "torn", "crumbled",
        "finely", "coarsely", "roughly", "thinly", "thickly", "freshly"
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
        // Looped rather than a single pass: `IngredientLineParser.normalize`
        // already collapses doubled/nested parens before this ever runs,
        // but a name built or edited some other way could still carry more
        // than one parenthetical, and `[^)]*` only ever strips one level
        // per pass.
        while result.range(of: #"\s*\([^)]*\)"#, options: .regularExpression) != nil {
            result = result.replacingOccurrences(
                of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression
            )
        }
        // A stray, unmatched paren can still be left behind — e.g. a
        // trailing ")" with no opening "(" on this side of a comma-split
        // that already happened above, or source text that was simply
        // malformed to begin with. Not a real ingredient character, so it's
        // always safe to drop rather than show it on the shopping list.
        result = result.replacingOccurrences(of: "(", with: "")
        result = result.replacingOccurrences(of: ")", with: "")

        // A comma right before a recognized prep/action word is a trailing
        // instruction ("chicken breast, diced", "onion, cut into thick
        // slices") and everything from there on gets dropped. A comma
        // *not* followed by one of those is far more likely separating
        // leading descriptors instead ("skinless, boneless chicken
        // thighs") — cutting there would wrongly truncate the name down to
        // just "Skinless", so it's left alone.
        if let commaIndex = result.firstIndex(of: ",") {
            let afterComma = result[result.index(after: commaIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let firstWord = afterComma
                .prefix(while: { $0.isLetter })
                .lowercased()
            if modifierWords.contains(firstWord) {
                result = String(result[result.startIndex..<commaIndex])
            }
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
