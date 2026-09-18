import Foundation

/// Turns a free-text ingredient line ("2 cups flour, sifted") into a
/// structured `RecipeIngredientEntry`. Used both for manual recipe entry
/// (type one ingredient per line) and for lines pulled from an imported URL.
enum IngredientLineParser {

    private static let knownUnits: Set<String> = [
        "cup", "cups", "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons", "tsp",
        "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs", "gram", "grams", "g",
        "kilogram", "kilograms", "kg", "milliliter", "milliliters", "ml", "liter", "liters", "l",
        "clove", "cloves", "can", "cans", "package", "packages", "pinch", "pinches",
        "slice", "slices", "piece", "pieces", "bunch", "bunches", "stick", "sticks",
        "quart", "quarts", "pint", "pints", "gallon", "gallons", "dash", "dashes",
        // Common count-nouns recipes use in place of a real unit ("1 loaf
        // brioche bread", "2 heads garlic") — without these, the noun stays
        // stuck at the front of the ingredient *name* instead of being
        // recognized as the measurement, which is exactly what let "loaf"
        // through into "Loaf Brioche Bread" on the grocery list.
        "loaf", "loaves", "head", "heads", "bag", "bags", "box", "boxes",
        "jar", "jars", "bottle", "bottles", "sprig", "sprigs", "stalk", "stalks",
        "bar", "bars", "container", "containers", "packet", "packets", "envelope", "envelopes"
    ]

    /// Maps every singular/plural/abbreviated spelling of a unit to one
    /// canonical display form, so "1 cup" from one recipe and "2 cups" from
    /// another land in the same bucket when the grocery list combines them
    /// instead of showing up as two separate, un-combined lines.
    private static let unitCanonicalForm: [String: String] = [
        "cup": "cups", "cups": "cups",
        "tablespoon": "tbsp", "tablespoons": "tbsp", "tbsp": "tbsp",
        "teaspoon": "tsp", "teaspoons": "tsp", "tsp": "tsp",
        "ounce": "oz", "ounces": "oz", "oz": "oz",
        "pound": "lbs", "pounds": "lbs", "lb": "lbs", "lbs": "lbs",
        "gram": "g", "grams": "g", "g": "g",
        "kilogram": "kg", "kilograms": "kg", "kg": "kg",
        "milliliter": "ml", "milliliters": "ml", "ml": "ml",
        "liter": "l", "liters": "l", "l": "l",
        "clove": "cloves", "cloves": "cloves",
        "can": "cans", "cans": "cans",
        "package": "packages", "packages": "packages",
        "pinch": "pinches", "pinches": "pinches",
        "slice": "slices", "slices": "slices",
        "piece": "pieces", "pieces": "pieces",
        "bunch": "bunches", "bunches": "bunches",
        "stick": "sticks", "sticks": "sticks",
        "quart": "quarts", "quarts": "quarts",
        "pint": "pints", "pints": "pints",
        "gallon": "gallons", "gallons": "gallons",
        "dash": "dashes", "dashes": "dashes",
        "loaf": "loaves", "loaves": "loaves",
        "head": "heads", "heads": "heads",
        "bag": "bags", "bags": "bags",
        "box": "boxes", "boxes": "boxes",
        "jar": "jars", "jars": "jars",
        "bottle": "bottles", "bottles": "bottles",
        "sprig": "sprigs", "sprigs": "sprigs",
        "stalk": "stalks", "stalks": "stalks",
        "bar": "bars", "bars": "bars",
        "container": "containers", "containers": "containers",
        "packet": "packets", "packets": "packets",
        "envelope": "envelopes", "envelopes": "envelopes"
    ]

    static func canonicalUnit(_ unit: String) -> String {
        unitCanonicalForm[unit.lowercased()] ?? unit.lowercased()
    }

    static func parse(_ rawLine: String) -> RecipeIngredientEntry {
        let trimmed = normalize(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RecipeIngredientEntry(name: "", rawText: "")
        }

        var scanner = Substring(trimmed)

        let quantity = consumeQuantity(&scanner)
        let unit = consumeUnit(&scanner)
        var name = scanner.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespaces)
        // "3 tablespoons OF lemon juice" — a unit is often followed by a
        // linking "of" before the actual ingredient ("of" is never itself
        // part of an ingredient's name). Left in place, it sticks to the
        // front of `name` ("of lemon juice"), which then fails to match the
        // same ingredient parsed without that connector elsewhere ("lemon
        // juice") once the grocery list tries to combine the two lines —
        // direct, confirmed report of exactly this ("I see lemon juice and
        // '3 tablespoons of lemon juice'" as two separate items).
        if unit != nil, name.lowercased().hasPrefix("of ") {
            name = String(name.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        let finalName = name.isEmpty ? trimmed : name
        return RecipeIngredientEntry(
            name: finalName,
            quantity: quantity,
            unit: unit,
            rawText: trimmed
        )
    }

    private static let unicodeFractions: [Character: String] = [
        "½": "1/2", "⅓": "1/3", "⅔": "2/3", "¼": "1/4", "¾": "3/4",
        "⅕": "1/5", "⅖": "2/5", "⅗": "3/5", "⅘": "4/5",
        "⅙": "1/6", "⅚": "5/6", "⅛": "1/8", "⅜": "3/8", "⅝": "5/8", "⅞": "7/8"
    ]

    /// Cleans up the messy formatting real recipe sites produce before
    /// quantity parsing ever sees the line: unicode fraction glyphs like "½"
    /// (which the quantity parser below can't read at all — they'd otherwise
    /// get stuck at the front of the ingredient *name*, which is exactly
    /// what made amounts hard to read), non-breaking spaces, and runs of
    /// repeated whitespace.
    private static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count + 8)
        var previousWasDigit = false
        for character in text {
            if let ascii = unicodeFractions[character] {
                // "1½" -> "1 1/2" (a mixed number needs a space between the
                // whole part and the fraction for the parser below to treat
                // it as one quantity); a bare "½" just becomes "1/2".
                if previousWasDigit {
                    result.append(" ")
                }
                result.append(ascii)
                result.append(" ")
                previousWasDigit = false
            } else {
                result.append(character)
                previousWasDigit = character.isNumber
            }
        }
        result = result
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return collapseDoubledParens(result)
    }

    /// Collapses "((...))"-style doubled/nested parenthetical wrapping down
    /// to a single pair, e.g. "bread ((Cut into thick slices))" ->
    /// "bread (Cut into thick slices)". Some source sites' structured data
    /// wraps an already-parenthesized note in an extra pair when it's
    /// concatenated together, which otherwise leaves a stray, unmatched ")"
    /// behind once `IngredientNameCleaner` strips just the inner pair — see
    /// its doc comment. Collapsing here, before anything else touches the
    /// line, means every downstream consumer (the recipe's own display,
    /// the grocery list) sees one well-formed pair no matter the source.
    private static func collapseDoubledParens(_ text: String) -> String {
        var result = text
        while let collapsed = matchOnce(#"\(\s*\("#, in: result, replacement: "(") {
            result = collapsed
        }
        while let collapsed = matchOnce(#"\)\s*\)"#, in: result, replacement: ")") {
            result = collapsed
        }
        // Tidy up the whitespace a collapse can leave just inside the
        // parens ("( sifted )" -> "(sifted)").
        result = result.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+\)"#, with: ")", options: .regularExpression)
        return result
    }

    private static func matchOnce(_ pattern: String, in text: String, replacement: String) -> String? {
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// Leading precision qualifiers ("scant 3/4 cup," "heaping 1/2
    /// teaspoon") — skipped over, not reflected in the parsed value (this
    /// app doesn't distinguish "scant" from "exact" anywhere), so the real
    /// quantity/unit right after one still gets recognized instead of the
    /// whole "qualifier + number + unit" staying stuck in the ingredient
    /// name for grocery-list purposes.
    private static let quantityQualifierWords: Set<String> = [
        "scant", "heaping", "rounded", "generous",
        // "about 3 cloves garlic," "roughly 1 lb butter" — an approximation
        // qualifier in front of the number, same treatment as "scant"/
        // "heaping" above. Direct, confirmed gap: these used to block
        // `consumeQuantity` from recognizing the number at all (it requires
        // a digit at the very start), leaving the entire line — number,
        // unit, and all — stuck as one unparsed name.
        "about", "roughly", "approximately", "around"
    ]

    /// Consumes a leading quantity like "2", "1.5", "1/2", "1 1/2",
    /// "4-5" (a range — see below), or "a"/"an" (see below) from the front
    /// of `text`, advancing it past the match, and returns the parsed value.
    private static func consumeQuantity(_ text: inout Substring) -> Double? {
        let original = text
        text = text.drop { $0 == " " }

        if let qualifierMatch = matchPrefix(of: text, pattern: #"^[A-Za-z]+\s+"#),
           quantityQualifierWords.contains(qualifierMatch.trimmingCharacters(in: .whitespaces).lowercased()) {
            text = text.dropFirst(qualifierMatch.count)
        }

        // Mixed number: "1 1/2", or "1 and 1/2" (the optional "and" is a
        // real, if less common, way recipes phrase this — direct,
        // confirmed gap: without it, only the leading "1" was recognized,
        // leaving "and 1/2 cups flour" stuck as the name). Digit runs
        // bounded for the same overflow reason as the decimal/integer case
        // below.
        if let mixed = matchPrefix(of: text, pattern: #"^(\d{1,6})\s+(?:and\s+)?(\d{1,6})\/(\d{1,6})\s*"#) {
            let comps = mixed.components(separatedBy: CharacterSet(charactersIn: " /"))
                .filter { !$0.isEmpty && $0.lowercased() != "and" }
            if comps.count == 3, let whole = Double(comps[0]), let num = Double(comps[1]), let den = Double(comps[2]), den != 0 {
                text = text.dropFirst(mixed.count)
                return whole + num / den
            }
        }
        // Simple fraction: "1/2"
        if let fraction = matchPrefix(of: text, pattern: #"^(\d{1,6})\/(\d{1,6})\s*"#) {
            let comps = fraction.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if comps.count == 2, let num = Double(comps[0]), let den = Double(comps[1]), den != 0 {
                text = text.dropFirst(fraction.count)
                return num / den
            }
        }
        // Range: "4-5 plum tomatoes," "5-6 large onions" (an en-/em-dash
        // separator works too — some sites use one instead of a plain
        // hyphen). Takes the UPPER bound as a "buy enough" estimate; this
        // app doesn't attempt precise cross-unit quantity math anywhere
        // else either, so approximating here is consistent, not a new
        // limitation. Tried before the plain decimal/integer case just
        // below — that one would otherwise greedily match just the "4" and
        // leave "-5" stuck at the front of the name.
        if let range = matchPrefix(of: text, pattern: #"^(\d{1,6}(\.\d+)?)\s*[-\u{2013}\u{2014}]\s*(\d{1,6}(\.\d+)?)\s*"#) {
            let comps = range.components(separatedBy: CharacterSet(charactersIn: "-\u{2013}\u{2014}"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if comps.count == 2, let upper = Double(comps[1]) {
                text = text.dropFirst(range.count)
                return upper
            }
        }
        // Decimal or integer: "2", "1.5". Capped at 6 digits before the
        // decimal point — no real recipe quantity needs more than that, and
        // without a cap a stray run of digits (garbled source markup, a
        // product code that landed in the ingredient text, ...) parses as a
        // quantity in the billions/trillions, which later formatting code
        // can't safely convert to an `Int`. Uncapped digits are left as text
        // instead of becoming a bogus quantity.
        if let number = matchPrefix(of: text, pattern: #"^(\d{1,6}(\.\d+)?)\s*"#) {
            let numeric = number.trimmingCharacters(in: .whitespaces)
            if let value = Double(numeric) {
                let remainder = text.dropFirst(number.count)
                // A digit run immediately followed by a letter with NO
                // space at all ("7UP", "10x sugar") is more likely a single
                // compound token (a brand/product name) than a real
                // "quantity space unit" pair — real recipe text almost
                // always has that space. Only roll back to leaving the
                // whole thing untouched when there's ALSO no recognized
                // unit right there to validate the split; "2tbsp sugar" (a
                // real, if uncommon, no-space compact notation) still
                // correctly parses as quantity 2 / unit tbsp, since "tbsp"
                // itself confirms the split was real. Direct, confirmed
                // gap: without this check, "7UP" parsed as quantity 7,
                // name "UP" — silently corrupting a real product name.
                let noSpaceConsumed = number.count == numeric.count
                if noSpaceConsumed, let nextCharacter = remainder.first, nextCharacter.isLetter {
                    var probe = remainder
                    if consumeUnit(&probe) == nil {
                        text = original
                        return nil
                    }
                }
                text = remainder
                return value
            }
        }
        // "a pinch of salt," "a dash of pepper," "a can of beans" — "a"/
        // "an" as an implicit quantity of 1, but ONLY when the very next
        // word is a real recognized unit ("pinch"/"dash"/"can"/...);
        // otherwise "a" is just the ordinary English article ("a whole
        // chicken," "a large onion") and must be left alone as part of the
        // name, not consumed as a phantom quantity. Direct, confirmed gap
        // from real recipe text: "a pinch of salt" was never recognized as
        // a quantity+unit at all (no leading digit for the usual path to
        // find), so it never merged with a plain "salt" from another
        // recipe.
        if let article = matchPrefix(of: text, pattern: #"^(a|an)\s+"#) {
            let afterArticle = text.dropFirst(article.count)
            var probe = afterArticle
            if consumeUnit(&probe) != nil {
                text = afterArticle
                return 1.0
            }
        }

        text = original
        return nil
    }

    /// Consumes a leading unit word ("cups", "tbsp", ...) if present.
    private static func consumeUnit(_ text: inout Substring) -> String? {
        let trimmedLeading = text.drop { $0 == " " }
        guard let firstWordRange = trimmedLeading.range(of: #"^[A-Za-z]+\.?"#, options: .regularExpression) else {
            return nil
        }
        let word = trimmedLeading[firstWordRange]
        let normalized = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard knownUnits.contains(normalized) else { return nil }

        let consumedCount = trimmedLeading.distance(from: trimmedLeading.startIndex, to: firstWordRange.upperBound)
        var remaining = trimmedLeading
        remaining.removeFirst(consumedCount)
        text = remaining.drop { $0 == " " }
        return String(word)
    }

    private static func matchPrefix(of text: Substring, pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        guard range.lowerBound == text.startIndex else { return nil }
        return String(text[range])
    }
}
