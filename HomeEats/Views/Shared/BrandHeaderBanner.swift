import SwiftUI

/// A small "Home Eats" masthead shown at the top of every tab's root screen.
/// Puts consistent brand identity in the content itself instead of leaning
/// on the nav bar's large title — which, on the tabs with a search bar or a
/// custom header row right underneath it, wasn't actually rendering usable
/// space so much as leaving a blank gap above that other content. Every tab
/// also sets `.navigationBarTitleDisplayMode(.inline)` alongside this, so
/// there's exactly one place branding/title text shows up, not a large
/// title fighting this banner for the same real estate.
struct BrandHeaderBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Home Eats")
                .font(.brandTitle3)
                .foregroundStyle(Color.brandForest)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.brandSage.opacity(0.15))
    }
}

/// The same banner, pre-shaped as a single, separatorless `List`/`Form` row
/// spanning the full width — for the tabs whose root content is a `List`
/// rather than a plain `VStack`.
extension View {
    func asBrandBannerRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
