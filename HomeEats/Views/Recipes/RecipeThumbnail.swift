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

    private var placeholder: some View {
        ZStack {
            Color.brandSage.opacity(0.15)
            Image(systemName: "fork.knife")
                .foregroundStyle(Color.brandSage)
                .font(.brandTitle)
        }
    }
}
