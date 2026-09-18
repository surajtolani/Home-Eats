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
    /// the name wherever they appear. A general trailing "for ...$" clause
    /// (not just the two specific "for serving"/"for garnish" phrases this
    /// used to list) covers any purpose note a recipe tacks onto an
    /// ingredient — direct, confirmed report: "water for rice" was showing
    /// up as its own grocery item instead of being recognized as plain
    /// water (which `isExcludedFromGroceryList` already skips, but only
    /// once "for rice" is gone). "water, for cooking rice" is caught the
    /// same way, the leading `,?` making the comma optional either way.
    private static let trailingPhrasePatterns: [String] = [
        #",?\s+to taste\.?$"#,
        #",?\s+for\s+.+$"#,
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
        "finely", "coarsely", "roughly", "thinly", "thickly", "freshly",
        // "fresh" (as opposed to "freshly", already listed above) — direct,
        // confirmed report: "grated ginger" and "grated fresh ginger" were
        // landing as two separate grocery lines instead of merging, since
        // "fresh" was the one leftover word keeping their canonical keys
        // apart.
        "fresh"
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

    /// `excludedNames` above is plain English, not pre-sorted into
    /// `GroceryListBuilder.canonicalKey`'s word-sorted form — "ice cube"
    /// canonicalizes to "cube ice", not "ice cube". Comparing a candidate's
    /// canonical key against the RAW literals would silently never match
    /// "ice cube" (the other entries happen to already be alphabetical by
    /// luck). Canonicalizing the excluded set itself keeps this correct
    /// regardless of word order in either list.
    private static let excludedCanonicalKeys: Set<String> = Set(
        excludedNames.map { GroceryListBuilder.canonicalKey(for: $0) }
    )

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

        // A raw ingredient line that never got its quantity/unit split out
        // at all (e.g. some AI-extracted or manually pasted lines) can
        // leave something like "3 tablespoons of lemon juice" sitting
        // whole in the name — re-running it through
        // `IngredientLineParser.parse` here recovers just the ingredient
        // part ("lemon juice") for grocery-list purposes ONLY (this never
        // touches the recipe's own stored ingredient, and this file has no
        // need to duplicate that parser's own quantity/unit vocabulary).
        // Gated on a unit actually being found — a bare leading number
        // alone ("2% milk", "10X sugar") is left completely alone, since
        // plenty of real product names start with a digit that isn't a
        // measurement at all.
        let reparsed = IngredientLineParser.parse(result)
        if reparsed.unit != nil, !reparsed.name.isEmpty {
            result = reparsed.name
        }
        // A leading "of" can still be left over even when the quantity/
        // unit were already correctly split out at the `RecipeIngredientEntry`
        // level (rather than needing the reparse fallback just above) —
        // "3 tbsp of lemon juice" -> quantity 3, unit "tbsp", name "of
        // lemon juice". Same reasoning as `IngredientLineParser.parse`'s
        // own "of"-stripping step (see that method's doc comment); kept as
        // a second, independent check here since that step only fires for
        // a *fresh* parse of the whole raw line, not for a name that's
        // already had its quantity/unit removed before this file ever sees
        // it.
        if result.lowercased().hasPrefix("of ") {
            result = String(result.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        // "1.2 kg / 2.4 lb chuck beef" — international-audience recipe
        // sites (RecipeTin Eats and similar) commonly give both metric and
        // imperial units separated by "/"; only the FIRST is ever consumed
        // above, leaving a stray leading "/ 2.4 lb ..." second measurement
        // stuck on the front of the name. This app doesn't attempt
        // cross-unit conversion/arithmetic anywhere (each unit gets its own
        // bucket — see `GroceryListBuilder.IngredientAggregate`), so this
        // is scoped to the display/matching name only, same "recover the
        // ingredient, not the numbers" spirit as the reparse step above.
        if result.hasPrefix("/") {
            let afterSlash = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
            let reparsedAfterSlash = IngredientLineParser.parse(afterSlash)
            if reparsedAfterSlash.unit != nil, !reparsedAfterSlash.name.isEmpty {
                result = reparsedAfterSlash.name
            } else {
                result = afterSlash
            }
        }

        // "1/2 cup plus 2 tablespoons unsalted butter" — a second "plus N
        // unit" quantity refinement between the already-consumed first
        // amount and the actual ingredient name (common in precise baking
        // recipes). Same "name-only, no arithmetic" scoping as the slash
        // case just above.
        if result.lowercased().hasPrefix("plus ") {
            let afterPlus = String(result.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let reparsedAfterPlus = IngredientLineParser.parse(afterPlus)
            if reparsedAfterPlus.unit != nil, !reparsedAfterPlus.name.isEmpty {
                result = reparsedAfterPlus.name
            } else {
                result = afterPlus
            }
            if result.lowercased().hasPrefix("of ") {
                result = String(result.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Known "combined seasoning" phrases that really describe two separate
    /// purchasable items, not one — split into their own constituent
    /// ingredients before ever reaching the grocery list, rather than
    /// either becoming an odd extra line of its own ("Salt And Pepper")
    /// alongside separately-listed "salt"/"pepper" entries from other
    /// recipes, or staying unmerged across every recipe's own choice of
    /// connector ("salt and pepper" vs. "salt + pepper" vs. "salt &
    /// pepper") — direct, confirmed report of exactly that fragmentation.
    /// Deliberately NOT a general "split on and" rule — that would wrongly
    /// break plenty of real single-ingredient names that happen to contain
    /// "and" ("mac and cheese", "peanut butter and jelly", "salt and
    /// vinegar chips") into nonsense fragments. This only matches this one,
    /// specific, extremely common seasoning pair, looked up after
    /// normalizing every spelling of its connector to the same form.
    private static let knownCombinedIngredients: [String: [String]] = [
        "salt and pepper": ["salt", "pepper"]
    ]

    /// Same cleanup as `groceryName(from:)`, but returns more than one name
    /// when the cleaned result is a known combined-ingredient phrase (see
    /// `knownCombinedIngredients`) — almost always a single-element array,
    /// same as `groceryName(from:)` wrapped in one.
    static func groceryNames(from rawName: String) -> [String] {
        let cleaned = groceryName(from: rawName)
        let normalizedConnector = cleaned
            .lowercased()
            .replacingOccurrences(of: #"\s*(\+|&|,?\s+and)\s*"#, with: " and ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let split = knownCombinedIngredients[normalizedConnector] {
            return split
        }
        return [cleaned]
    }

    /// Whether a (already-cleaned) grocery name is something that should
    /// never actually be added to the list.
    static func isExcludedFromGroceryList(_ cleanedName: String) -> Bool {
        excludedCanonicalKeys.contains(GroceryListBuilder.canonicalKey(for: cleanedName))
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
