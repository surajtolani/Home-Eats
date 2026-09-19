import Foundation

/// A recipe's course/occasion — multi-select per recipe (e.g. a dish can
/// legitimately be both a "Snack" and "Seasonal"). Kept separate from
/// `MealSlot` (breakfast/lunch/dinner/other), which is about *when* a meal
/// is planned, not what kind of dish it is.
enum MealCourse: String, Codable, CaseIterable, Identifiable {
    case appetizer = "Appetizer"
    case mainCourse = "Main Course"
    case soupSalad = "Soup/Salad"
    case dessert = "Dessert"
    case snack = "Snack"
    case seasonal = "Seasonal"

    var id: String { rawValue }
}

/// A fixed list of common cuisines. Used both to auto-suggest a recipe's
/// cuisine from its title/ingredients (`guess(title:ingredientNames:)`) and
/// to populate the multi-select picker a user corrects or adds to that
/// guess with — a recipe (unlike `Restaurant.cuisine`, which is whatever
/// free text Google Places returns) has no external source for this, so it
/// needs a finite set to guess from and choose among instead.
enum CuisineType: String, Codable, CaseIterable, Identifiable {
    case american = "American"
    case italian = "Italian"
    case mexican = "Mexican"
    case chinese = "Chinese"
    case japanese = "Japanese"
    case thai = "Thai"
    case vietnamese = "Vietnamese"
    case korean = "Korean"
    case indian = "Indian"
    case frenchCuisine = "French"
    case mediterranean = "Mediterranean"
    case greek = "Greek"
    case middleEastern = "Middle Eastern"
    case spanish = "Spanish"
    case caribbean = "Caribbean"
    case german = "German"
    case british = "British"
    case african = "African"
    case other = "Other"

    var id: String { rawValue }

    /// Cheap keyword match against a recipe's title and ingredient lines —
    /// same "easy-to-correct heuristic, not a real classifier" spirit as
    /// `GroceryCategory.guess(fromIngredientName:)`. Returns every cuisine
    /// whose keywords hit (not just the first), since a title like "Korean
    /// Tacos" legitimately hints at two, and the caller pre-selects
    /// whatever comes back for the user to prune or add to.
    static func guess(title: String, ingredientNames: [String]) -> [CuisineType] {
        let haystack = ([title] + ingredientNames).joined(separator: " ").lowercased()
        return keywordOrderedCases.filter { cuisine in
            (keywordMap[cuisine] ?? []).contains { haystack.contains($0) }
        }
    }

    /// `keywordMap`'s keys in a stable, deliberate order (rather than
    /// `Dictionary`'s unordered `Set<Key>`), so a title matching several
    /// cuisines always pre-selects them in the same order every time.
    private static let keywordOrderedCases: [CuisineType] = [
        .italian, .mexican, .chinese, .japanese, .thai, .vietnamese, .korean, .indian,
        .frenchCuisine, .mediterranean, .greek, .middleEastern, .spanish, .caribbean,
        .german, .british, .african,
    ]

    private static let keywordMap: [CuisineType: [String]] = [
        .italian: ["italian", "pasta", "parmesan", "marinara", "risotto", "pesto", "lasagna", "gnocchi"],
        .mexican: ["mexican", "taco", "tortilla", "salsa", "enchilada", "burrito", "queso", "chipotle", "guacamole"],
        .chinese: ["chinese", "soy sauce", "hoisin", "bok choy", "wonton", "szechuan", "sichuan", "stir fry", "stir-fry"],
        .japanese: ["japanese", "miso", "sushi", "teriyaki", "wasabi", "dashi", "panko", "udon", "ramen"],
        .thai: ["thai", "fish sauce", "lemongrass", "coconut milk", "curry paste", "basil leaves", "pad thai"],
        .vietnamese: ["vietnamese", "pho", "banh mi", "nuoc cham"],
        .korean: ["korean", "gochujang", "kimchi", "bulgogi", "bibimbap"],
        .indian: ["indian", "curry", "garam masala", "turmeric", "tikka", "naan", "basmati", "paneer"],
        .frenchCuisine: ["french", "baguette", "brie", "dijon", "bechamel", "béchamel", "croissant", "ratatouille"],
        .mediterranean: ["mediterranean", "olive oil", "hummus", "tzatziki", "pita"],
        .greek: ["greek", "feta", "tzatziki", "oregano", "gyro"],
        .middleEastern: ["middle eastern", "tahini", "falafel", "shawarma", "za'atar", "zaatar"],
        .spanish: ["spanish", "paella", "chorizo", "saffron", "manchego"],
        .caribbean: ["caribbean", "jerk", "plantain", "jamaican"],
        .german: ["german", "bratwurst", "sauerkraut", "schnitzel"],
        .british: ["british", "yorkshire pudding", "shepherd's pie", "bangers"],
        .african: ["ethiopian", "moroccan", "injera", "tagine", "berbere"],
    ]
}
