import Foundation

/// A single ingredient line on a recipe. This is a plain Codable value type
/// (not a SwiftData `@Model`) so it can live as an array directly on `Recipe`
/// without needing its own table/relationship.
struct RecipeIngredientEntry: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// The normalized ingredient name, e.g. "yellow onion".
    var name: String
    var quantity: Double?
    var unit: String?
    var category: GroceryCategory
    /// The original text as typed or parsed. Kept for reference, but
    /// `displayText` prefers a freshly-formatted line whenever a quantity
    /// was successfully parsed — see its doc comment for why.
    var rawText: String

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Double? = nil,
        unit: String? = nil,
        category: GroceryCategory? = nil,
        rawText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.category = category ?? GroceryCategory.guess(fromIngredientName: name)
        self.rawText = rawText ?? Self.formattedLine(quantity: quantity, unit: unit, name: name)
    }

    /// Builds a clean, consistently-formatted ingredient line from parsed
    /// parts, e.g. "1 1/2 cups flour" — always a single space between
    /// quantity/unit/name, always our own fraction rendering.
    static func formattedLine(quantity: Double?, unit: String?, name: String) -> String {
        var parts: [String] = []
        if let quantity {
            parts.append(IngredientQuantityFormatter.string(for: quantity))
        }
        if let unit, !unit.isEmpty {
            parts.append(unit)
        }
        parts.append(name)
        return parts.joined(separator: " ")
    }

    /// The line shown in the recipe view. Whenever we successfully parsed a
    /// quantity, this is *regenerated* from (quantity, unit, name) rather
    /// than showing the original source text — imported recipes come from
    /// sites that format fractions all sorts of ways (unicode glyphs like
    /// "½", inconsistent spacing, no space between a whole number and a
    /// fraction), which is exactly what made amounts hard to read at a
    /// glance. Regenerating keeps every ingredient's formatting consistent
    /// regardless of source. Only falls back to the raw text when no
    /// quantity could be parsed at all (e.g. "Salt to taste").
    var displayText: String {
        if quantity != nil {
            return Self.formattedLine(quantity: quantity, unit: unit, name: name.titleCasedForDisplay)
        }
        let text = rawText.isEmpty ? name : rawText
        return text.titleCasedForDisplay
    }
}

enum IngredientQuantityFormatter {
    static func string(for value: Double) -> String {
        // `Int(_: Double)` traps on a value that isn't finite or doesn't fit
        // in an `Int` — possible here since this also formats *summed*
        // quantities from GroceryListBuilder (several recipes' amounts added
        // together), not just a single parsed line. Anything outside a sane
        // range for a grocery quantity falls back to plain decimal text
        // instead of risking a crash.
        guard value.isFinite, abs(value) < 1_000_000_000 else {
            return String(format: "%.2f", value.isFinite ? value : 0)
        }

        // Absorb floating-point summation noise (three 1/3-cup ingredients
        // add up to 0.9999999999999999, not 1.0) before checking for a whole
        // number or a fraction match below — otherwise that lands in neither
        // and prints as the confusing "1.00" instead of "1".
        let value = (value * 10_000).rounded() / 10_000

        if value == value.rounded() {
            return String(Int(value))
        }
        // Render common cooking fractions nicely (1.5 -> "1 1/2") since
        // that's how recipes actually read. Every fraction here matches one
        // `IngredientLineParser` can parse from a unicode glyph (½ ⅓ ⅔ ¼ ¾
        // ⅕ ⅖ ⅗ ⅘ ⅙ ⅚ ⅛ ⅜ ⅝ ⅞) — computed the same way (as num/den) so a
        // parsed value lands almost exactly on its table entry instead of
        // needing the tolerance below to find it. A fraction missing from
        // this table isn't just an ugly decimal fallback: it can match the
        // *wrong* nearby entry within tolerance and silently show a
        // different quantity than was parsed, which is worse.
        let whole = Int(value)
        let fraction = value - Double(whole)
        let fractionsTable: [(Double, String)] = [
            (1.0 / 8, "1/8"), (1.0 / 6, "1/6"), (1.0 / 5, "1/5"), (1.0 / 4, "1/4"),
            (1.0 / 3, "1/3"), (3.0 / 8, "3/8"), (2.0 / 5, "2/5"), (1.0 / 2, "1/2"),
            (3.0 / 5, "3/5"), (5.0 / 8, "5/8"), (2.0 / 3, "2/3"), (3.0 / 4, "3/4"),
            (4.0 / 5, "4/5"), (5.0 / 6, "5/6"), (7.0 / 8, "7/8")
        ]
        if let match = fractionsTable.min(by: { abs($0.0 - fraction) < abs($1.0 - fraction) }),
           abs(match.0 - fraction) < 0.01 {
            return whole > 0 ? "\(whole) \(match.1)" : match.1
        }
        return String(format: "%.2f", value)
    }
}
