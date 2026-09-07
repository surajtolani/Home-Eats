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
        "quart", "quarts", "pint", "pints", "gallon", "gallons", "dash", "dashes"
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
        "dash": "dashes", "dashes": "dashes"
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
        let name = scanner.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .trimmingCharacters(in: .whitespaces)

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
        return result
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    /// Consumes a leading quantity like "2", "1.5", "1/2", or "1 1/2" from the
    /// front of `text`, advancing it past the match, and returns the parsed value.
    private static func consumeQuantity(_ text: inout Substring) -> Double? {
        let original = text
        text = text.drop { $0 == " " }

        // Mixed number: "1 1/2" (digit runs bounded for the same overflow
        // reason as the decimal/integer case below).
        if let mixed = matchPrefix(of: text, pattern: #"^(\d{1,6})\s+(\d{1,6})\/(\d{1,6})\s*"#) {
            let comps = mixed.components(separatedBy: CharacterSet(charactersIn: " /"))
                .filter { !$0.isEmpty }
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
                text = text.dropFirst(number.count)
                return value
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
