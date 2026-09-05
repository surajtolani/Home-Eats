import Foundation

/// Store-aisle style categories used to group the grocery list.
/// Keeping this as a flat enum (rather than free-text) is what lets us
/// auto-sort ingredients into sections without the user doing any work.
enum GroceryCategory: String, Codable, CaseIterable, Identifiable {
    case produce
    case dairyAndEggs
    case meatAndSeafood
    case bakery
    case pantry
    case frozen
    case beverages
    case snacks
    case household
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .produce: return "Produce"
        case .dairyAndEggs: return "Dairy & Eggs"
        case .meatAndSeafood: return "Meat & Seafood"
        case .bakery: return "Bakery"
        case .pantry: return "Pantry"
        case .frozen: return "Frozen"
        case .beverages: return "Beverages"
        case .snacks: return "Snacks"
        case .household: return "Household"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .produce: return "carrot"
        case .dairyAndEggs: return "cup.and.saucer"
        case .meatAndSeafood: return "fish"
        case .bakery: return "birthday.cake"
        case .pantry: return "cabinet"
        case .frozen: return "snowflake"
        case .beverages: return "waterbottle"
        case .snacks: return "popcorn"
        case .household: return "house"
        case .other: return "basket"
        }
    }

    /// Sort order for displaying the grocery list the way most stores are laid out.
    var sortIndex: Int {
        switch self {
        case .produce: return 0
        case .bakery: return 1
        case .dairyAndEggs: return 2
        case .meatAndSeafood: return 3
        case .frozen: return 4
        case .pantry: return 5
        case .snacks: return 6
        case .beverages: return 7
        case .household: return 8
        case .other: return 9
        }
    }

    /// Very small keyword table used to auto-categorize ingredients that don't
    /// already carry a category (e.g. freshly parsed from an imported URL).
    /// This is intentionally simple per the spec's "start simple" guidance.
    static func guess(fromIngredientName name: String) -> GroceryCategory {
        let n = name.lowercased()

        func has(_ words: String...) -> Bool {
            words.contains { n.contains($0) }
        }

        if has("chicken", "beef", "pork", "turkey", "sausage", "bacon", "shrimp", "salmon", "fish", "steak", "ground meat", "tofu") {
            return .meatAndSeafood
        }
        if has("milk", "cheese", "yogurt", "butter", "cream", "egg", "eggs") {
            return .dairyAndEggs
        }
        if has("bread", "bun", "bagel", "tortilla", "roll", "baguette") {
            return .bakery
        }
        if has("frozen", "ice cream", "pizza roll") {
            return .frozen
        }
        if has("soda", "juice", "water", "coffee", "tea", "wine", "beer", "sparkling") {
            return .beverages
        }
        if has("chip", "cracker", "pretzel", "popcorn", "cookie", "candy") {
            return .snacks
        }
        if has("paper towel", "napkin", "detergent", "foil", "trash bag", "soap", "dish", "sponge") {
            return .household
        }
        if has(
            "onion", "garlic", "tomato", "lettuce", "spinach", "pepper", "carrot", "potato",
            "broccoli", "cucumber", "avocado", "lime", "lemon", "apple", "banana", "herb",
            "cilantro", "parsley", "basil", "mushroom", "zucchini", "kale", "berries"
        ) {
            return .produce
        }
        if has(
            "flour", "sugar", "rice", "pasta", "beans", "oil", "sauce", "spice", "salt",
            "pepper flakes", "broth", "stock", "canned", "cereal", "oats", "nut", "vinegar", "honey"
        ) {
            return .pantry
        }
        return .other
    }
}
