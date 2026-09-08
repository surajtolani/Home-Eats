import SwiftUI

/// The "Home Eats" primary horizontal logo, shown in the navigation bar's
/// centered (`.principal`) toolbar slot on every tab's root screen, in
/// place of that screen's own title text. This is what makes it "the top
/// of the app" — the nav bar itself is the one piece of chrome that's
/// unavoidably above all content on every screen; a banner rendered as
/// regular content, by contrast, only ever sits *below* the nav bar; on the
/// tabs with a search bar or a custom header row right underneath it, that
/// gap read as a blank space rather than a rendered title.
/// `.navigationTitle` is still set on each screen (needed so the *back*
/// button reads "Recipes" etc. when pushing from here) — it's just not
/// what's visually displayed once this replaces it.
///
/// `BrandWordmark` is the brand sheet's "Primary Logo (Horizontal)" artwork,
/// cropped straight from that sheet with its background made transparent —
/// with one recolor: the house's walls+base (as distinct from its roof, the
/// heart, and the fork/knife/spoon, which all stay the original olive) are
/// tinted Sage, per request.
struct BrandHeaderBanner: View {
    var body: some View {
        Image("BrandWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: 28)
    }
}
