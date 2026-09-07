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
            return Self.formattedLine(quantity: quantity, unit: unit, name: name)
        }
        return rawText.isEmpty ? name : rawText
    }
}

enum IngredientQuantityFormatter {
    static func string(for value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        // Render common cooking fractions nicely (1.5 -> "1 1/2") since
        // that's how recipes actually read, down to eighths (baking
        // measurements routinely use 1/8 and 3/8).
        let whole = Int(value)
        let fraction = value - Double(whole)
        let fractionsTable: [(Double, String)] = [
            (0.125, "1/8"), (0.25, "1/4"), (1.0 / 3.0, "1/3"), (0.375, "3/8"),
            (0.5, "1/2"), (0.625, "5/8"), (2.0 / 3.0, "2/3"), (0.75, "3/4"), (0.875, "7/8")
        ]
        if let match = fractionsTable.min(by: { abs($0.0 - fraction) < abs($1.0 - fraction) }),
           abs(match.0 - fraction) < 0.03 {
            return whole > 0 ? "\(whole) \(match.1)" : match.1
        }
        return String(format: "%.2f", value)
    }
}
