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
    /// The original text as typed or parsed, kept so the recipe view can
    /// always show exactly what the source said (e.g. "2 large onions, diced").
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
        self.rawText = rawText ?? Self.formatRawText(quantity: quantity, unit: unit, name: name)
    }

    private static func formatRawText(quantity: Double?, unit: String?, name: String) -> String {
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

    /// A display line combining quantity, unit and name, e.g. "2 cups flour".
    var displayText: String {
        rawText.isEmpty ? name : rawText
    }
}

enum IngredientQuantityFormatter {
    static func string(for value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        // Render common fractions nicely (1.5 -> "1 1/2") since recipes read that way.
        let whole = Int(value)
        let fraction = value - Double(whole)
        let fractionsTable: [(Double, String)] = [
            (0.25, "1/4"), (0.33, "1/3"), (0.5, "1/2"), (0.66, "2/3"), (0.75, "3/4")
        ]
        if let match = fractionsTable.min(by: { abs($0.0 - fraction) < abs($1.0 - fraction) }),
           abs(match.0 - fraction) < 0.05 {
            return whole > 0 ? "\(whole) \(match.1)" : match.1
        }
        return String(format: "%.2f", value)
    }
}
