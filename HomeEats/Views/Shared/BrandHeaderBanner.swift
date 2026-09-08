import SwiftUI

/// The "Home Eats" mark shown in the navigation bar's center (`.principal`
/// toolbar slot) on every tab's root screen, in place of that screen's own
/// title text. This is what makes it "the top of the app" — the nav bar
/// itself is the one piece of chrome that's unavoidably above all content
/// on every screen; a banner rendered as regular content, by contrast, only
/// ever sits *below* the nav bar; on the tabs with a search bar or a custom
/// header row right underneath it, that gap read as a blank space rather
/// than a rendered title. `.navigationTitle` is still set on each screen
/// (needed so the *back* button reads "Recipes" etc. when pushing from
/// here) — it's just not what's visually displayed once this replaces it.
struct BrandHeaderBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("Home Eats")
                .font(.brandHeadline)
                .foregroundStyle(Color.brandForest)
        }
    }
}
