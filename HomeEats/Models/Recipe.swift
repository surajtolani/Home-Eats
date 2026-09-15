import Foundation
import SwiftData

enum RecipeSource: String, Codable {
    /// Typed in by a family member.
    case manual
    /// Auto-imported by pasting a URL.
    case imported
    /// Came from the app's built-in recipe library.
    case library
    /// Saved from another Home Eats user's "Shared" recipe (a friend or a
    /// group shared it via the backend's recipe-sharing API — see
    /// `AccountsAPIClient`/`RecipesHomeView`'s "Shared" section). Reuses the
    /// exact same "browseable, not yet mine until saved" idea `.library`
    /// already established rather than inventing a second mechanism — the
    /// difference is *where* the not-yet-saved copy lives: a `.library`
    /// recipe already exists locally with `isSavedToCollection == false`,
    /// while a `.shared` recipe isn't a local `Recipe` row at all until the
    /// moment it's saved (friends/groups are fetched live from the backend
    /// per that feature's design, not mirrored into SwiftData) — so a
    /// `.shared` recipe is only ever created already-saved
    /// (`isSavedToCollection` defaults to `true`, same as `.manual`/
    /// `.imported`).
    case shared
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
    /// This recipe's id on the backend's recipe-sharing API
    /// (`POST /recipe-library`'s response — see `AccountsAPIClient`), once
    /// it's ever been shared. `nil` for the overwhelming majority of
    /// recipes, which stay purely local/on-device forever per this app's
    /// local-first design — sharing is opt-in and per-recipe, not a
    /// big-bang migration of existing data to the backend (see
    /// `RecipeSharePickerSheet`, which sets this the first time a recipe is
    /// shared). Kept around after that first share so re-sharing or editing
    /// later reuses the same backend row instead of creating a duplicate
    /// one on every share. Optional with no explicit default needed for
    /// migration (a `String?` already defaults to `nil`) — same reasoning
    /// as `sourceURL`/`imageName` above; unlike `layoutOrderIndex` on
    /// `GroceryItem` (a non-optional `Double` that needs an explicit
    /// `= 0` for SwiftData's lightweight migration to apply this field to
    /// existing rows), an optional needs no such default.
    var backendRecipeID: String?
    /// Whether this recipe has been published to the master library (backend
    /// `visibility: "PUBLIC"` — see `POST /recipe-library/:recipeId/publish`)
    /// — a one-way flag, never cleared back to `false`, matching the
    /// backend's own "PUBLIC never reverts" rule. Defaulted (not just in the
    /// initializer) so adding this to existing `Recipe` rows stays a
    /// lightweight SwiftData migration, same reasoning as `isFavorite`'s own
    /// doc comment.
    var isPublishedToLibrary: Bool = false

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
        createdByMemberID: UUID? = nil,
        backendRecipeID: String? = nil,
        isPublishedToLibrary: Bool = false
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
        self.backendRecipeID = backendRecipeID
        self.isPublishedToLibrary = isPublishedToLibrary
    }

    var totalMinutes: Int { prepMinutes + cookMinutes }
}
