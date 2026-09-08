import Foundation
import SwiftData

enum RecipeSource: String, Codable {
    /// Typed in by a family member.
    case manual
    /// Auto-imported by pasting a URL.
    case imported
    /// Came from the app's built-in recipe library.
    case library
}

@Model
final class Recipe {
    @Attribute(.unique) var id: UUID
    var title: String
    var source: RecipeSource
    /// The page it was imported from, if any.
    var sourceURL: String?
    var summary: String?
    /// Ordered step-by-step cooking instructions, shown in the recipe view.
    var instructions: [String]
    /// The ingredient list; each entry carries its own grocery category so
    /// the shopping list can be auto-sorted without extra user input.
    var ingredients: [RecipeIngredientEntry]
    var servings: Int
    var prepMinutes: Int
    var cookMinutes: Int
    var tags: [String]
    /// True once the user has saved a *library* recipe into their own
    /// collection (per spec: library recipes are separate until saved).
    var isSavedToCollection: Bool
    /// Name of a bundled image asset (library recipes), or the remote photo
    /// URL a page's schema.org data pointed at (imported recipes).
    /// Distinguished at render time by whether it looks like a URL — see
    /// `RecipeThumbnail`.
    var imageName: String?
    /// A photo the user picked/took themselves, for manually-entered
    /// recipes. Takes priority over `imageName` when both are set. Optional
    /// with no default needed for migration (unlike a `Bool`, `Data?`
    /// already defaults to nil).
    var photoData: Data?
    /// Defaulted (not just in the initializer) so adding this to existing
    /// `Recipe` rows stays a lightweight SwiftData migration.
    var isFavorite: Bool = false
    var createdAt: Date
    /// The family member who added/imported this recipe, if known.
    var createdByMemberID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        source: RecipeSource = .manual,
        sourceURL: String? = nil,
        summary: String? = nil,
        instructions: [String] = [],
        ingredients: [RecipeIngredientEntry] = [],
        servings: Int = 4,
        prepMinutes: Int = 0,
        cookMinutes: Int = 0,
        tags: [String] = [],
        isSavedToCollection: Bool = true,
        imageName: String? = nil,
        photoData: Data? = nil,
        isFavorite: Bool = false,
        createdAt: Date = .now,
        createdByMemberID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.sourceURL = sourceURL
        self.summary = summary
        self.instructions = instructions
        self.ingredients = ingredients
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.tags = tags
        self.isSavedToCollection = isSavedToCollection
        self.imageName = imageName
        self.photoData = photoData
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.createdByMemberID = createdByMemberID
    }

    var totalMinutes: Int { prepMinutes + cookMinutes }
}
