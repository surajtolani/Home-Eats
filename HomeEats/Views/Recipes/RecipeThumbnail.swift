import SwiftUI
import UIKit

/// A recipe's photo, wherever one is available: a user-picked photo takes
/// priority, then a remote URL (imported recipes carry the source page's own
/// photo URL, parsed straight out of its schema.org data), then a bundled
/// asset (library recipes), then a plain placeholder icon.
struct RecipeThumbnail: View {
    let recipe: Recipe

    var body: some View {
        Group {
            if let photoData = recipe.photoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let imageName = recipe.imageName, let url = remoteURL(imageName) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else if let imageName = recipe.imageName, UIImage(named: imageName) != nil {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
    }

    private func remoteURL(_ imageName: String) -> URL? {
        guard imageName.lowercased().hasPrefix("http") else { return nil }
        return URL(string: imageName)
    }

    /// A generic fork-and-knife placeholder reads as identical, undifferentiated
    /// filler across a whole grid of recipes with no real photo — most
    /// visibly the app's own 10 bundled `.library` recipes, which have
    /// never shipped with real photos at all (`BuiltInRecipes.json` has no
    /// image field — a real gap, not a regression, but one worth making
    /// look intentional rather than broken). Picking the icon from
    /// `recipe.tags` (case-insensitive keyword match, same tags either
    /// bundled seed data or a user's own comma-separated "Tags" field on
    /// `RecipeEditorView` already provide — no new data needed) gives at
    /// least some of these a placeholder that actually fits the dish,
    /// rather than every recipe with no photo looking the same. Only two,
    /// deliberately conservative categories — both unambiguous, long-
    /// standing SF Symbols — rather than guessing at less certain ones for
    /// every possible cuisine; everything else keeps the original
    /// fork-and-knife.
    private var placeholder: some View {
        ZStack {
            Color.brandSage.opacity(0.15)
            Image(systemName: placeholderSymbolName)
                .foregroundStyle(Color.brandSage)
                .font(.brandTitle)
        }
    }

    private var placeholderSymbolName: String {
        let tags = recipe.tags.map { $0.lowercased() }
        if tags.contains(where: { $0.contains("seafood") || $0.contains("fish") || $0.contains("salmon") || $0.contains("shrimp") }) {
            return "fish.fill"
        }
        if tags.contains(where: { $0.contains("vegetarian") || $0.contains("vegan") }) {
            return "leaf.fill"
        }
        return "fork.knife"
    }
}
