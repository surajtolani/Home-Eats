import Foundation
import SwiftData

/// Populates first-launch data: the built-in recipe library, a starter set of
/// household staples, and the singleton `AppSettings` row. Runs once — every
/// call is a cheap no-op after the first, so it's safe to call from
/// `HomeEatsApp` on every launch.
@MainActor
enum SampleDataSeeder {

    static func seedIfNeeded(context: ModelContext) {
        seedSettingsIfNeeded(context: context)
        seedLibraryRecipesIfNeeded(context: context)
        seedStaplesIfNeeded(context: context)
        seedDefaultLayoutAislesIfNeeded(context: context)
    }

    private static func seedSettingsIfNeeded(context: ModelContext) {
        let id = AppSettings.singletonID
        let descriptor = FetchDescriptor<AppSettings>(predicate: #Predicate { $0.id == id })
        if (try? context.fetch(descriptor))?.isEmpty ?? true {
            context.insert(AppSettings())
        }
    }

    private static func seedLibraryRecipesIfNeeded(context: ModelContext) {
        // Filtering on a custom enum inside #Predicate is unreliable on
        // early iOS 17 SwiftData, so fetch everything and filter in Swift.
        let allRecipes = (try? context.fetch(FetchDescriptor<Recipe>())) ?? []
        guard !allRecipes.contains(where: { $0.source == .library }) else { return }
        guard let seeds = loadSeedRecipes() else { return }

        for seed in seeds {
            let ingredients = seed.ingredientLines.map(IngredientLineParser.parse)
            let recipe = Recipe(
                title: seed.title,
                source: .library,
                summary: seed.summary,
                instructions: seed.instructions,
                ingredients: ingredients,
                servings: seed.servings,
                prepMinutes: seed.prepMinutes,
                cookMinutes: seed.cookMinutes,
                tags: seed.tags,
                isSavedToCollection: false
            )
            context.insert(recipe)
        }
    }

    private static func seedStaplesIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<StapleItem>()
        guard (try? context.fetch(descriptor))?.isEmpty ?? true else { return }

        let starterStaples: [(String, GroceryCategory)] = [
            ("Milk", .dairyAndEggs),
            ("Eggs", .dairyAndEggs),
            ("Bread", .bakery),
            ("Coffee", .pantry),
            ("Paper towels", .household),
            ("Dish soap", .household),
            ("Bananas", .produce),
            ("Butter", .dairyAndEggs)
        ]
        for (name, category) in starterStaples {
            context.insert(StapleItem(name: name, category: category))
        }
    }

    /// Seeds one "My Layout" aisle per `GroceryCategory`, in the same
    /// walking order "By Category" already sorts by, so "My Layout" opens
    /// grouped the same way "By Category" is instead of dumping every item
    /// into "Unsorted" until someone manually places it there one at a
    /// time. Only runs while `StoreAisle` is completely empty — a household
    /// that's already started defining their own aisles (even just one)
    /// keeps exactly what they made instead of this splicing ten more in
    /// alongside it.
    private static func seedDefaultLayoutAislesIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<StoreAisle>()
        guard (try? context.fetch(descriptor))?.isEmpty ?? true else { return }

        for category in GroceryCategory.allCases.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            context.insert(StoreAisle(
                name: category.displayName,
                sortIndex: category.sortIndex,
                linkedCategory: category
            ))
        }
    }

    private struct SeedRecipe: Codable {
        var title: String
        var summary: String?
        var ingredientLines: [String]
        var instructions: [String]
        var servings: Int
        var prepMinutes: Int
        var cookMinutes: Int
        var tags: [String]
    }

    private static func loadSeedRecipes() -> [SeedRecipe]? {
        guard let url = Bundle.main.url(forResource: "BuiltInRecipes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([SeedRecipe].self, from: data)
    }
}
