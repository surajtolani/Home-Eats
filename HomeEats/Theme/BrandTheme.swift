import SwiftUI

/// Home Eats brand colors, pulled from the brand guidelines sheet.
/// Each of these backs a fixed (non dark-mode-adaptive) color asset in
/// Assets.xcassets — the brand palette is meant to look the same regardless
/// of system appearance, the way the guidelines sheet defines it once.
extension Color {
    /// Primary brand green. Also backs `AccentColor`, so this is the app's
    /// tint color everywhere SwiftUI/UIKit look one up automatically
    /// (selected tab items, links, default button tint, toggles, etc.) —
    /// most views need no explicit color code at all to pick it up.
    static let brandOlive = Color("BrandOlive")
    /// Deep green used for primary text/headlines and "home cooked" status.
    static let brandForest = Color("BrandForest")
    /// Muted secondary green.
    static let brandSage = Color("BrandSage")
    /// Off-white background tone used in place of plain white/systemBackground.
    static let brandCream = Color("BrandCream")
    /// Warm accent used for "eating out" status and secondary call-to-actions.
    static let brandTerracotta = Color("BrandTerracotta")
    /// Accent used sparingly for highlights (e.g. badges, ratings).
    static let brandHoney = Color("BrandHoney")
    /// Soft accent for gentle emphasis (e.g. subtle banners).
    static let brandBlush = Color("BrandBlush")
    /// Neutral warm tone, an alternative to system gray fills.
    static let brandSand = Color("BrandSand")
}

/// Nunito-based type scale that mirrors the system Dynamic Type text styles
/// it replaces (`.brandTitle` stands in for `.title`, etc.), including
/// `relativeTo:` so Dynamic Type / accessibility text sizing still works.
/// Weights follow the brand sheet: Bold for large titles/headlines, SemiBold
/// for emphasis, Regular for body copy.
extension Font {
    static let brandLargeTitle = Font.custom("Nunito-Bold", size: 34, relativeTo: .largeTitle)
    static let brandTitle = Font.custom("Nunito-Bold", size: 28, relativeTo: .title)
    static let brandTitle2 = Font.custom("Nunito-Bold", size: 22, relativeTo: .title2)
    static let brandTitle3 = Font.custom("Nunito-SemiBold", size: 20, relativeTo: .title3)
    static let brandHeadline = Font.custom("Nunito-SemiBold", size: 17, relativeTo: .headline)
    static let brandBody = Font.custom("Nunito-Regular", size: 17, relativeTo: .body)
    static let brandCallout = Font.custom("Nunito-Regular", size: 16, relativeTo: .callout)
    static let brandSubheadline = Font.custom("Nunito-Regular", size: 15, relativeTo: .subheadline)
    static let brandFootnote = Font.custom("Nunito-Regular", size: 13, relativeTo: .footnote)
    static let brandCaption = Font.custom("Nunito-Regular", size: 12, relativeTo: .caption)
    static let brandCaption2 = Font.custom("Nunito-Medium", size: 11, relativeTo: .caption2)
}

/// One-time UIKit chrome setup (nav bars, tab bars) so the brand's font and
/// colors apply to system-drawn bars, which SwiftUI's `.font`/`.tint`
/// modifiers don't reach. Call once, e.g. from the app's `init()`.
enum BrandAppearance {
    static func apply() {
        let forest = UIColor(Color.brandForest)
        let olive = UIColor(Color.brandOlive)
        let cream = UIColor(Color.brandCream)
        let titleFont = UIFont(name: "Nunito-Bold", size: 17) ?? UIFont.boldSystemFont(ofSize: 17)
        let largeTitleFont = UIFont(name: "Nunito-Bold", size: 34) ?? UIFont.boldSystemFont(ofSize: 34)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = cream
        navAppearance.titleTextAttributes = [.foregroundColor: forest, .font: titleFont]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: forest, .font: largeTitleFont]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = olive

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = cream
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = olive

        // Almost every screen in the app is a grouped List; this tints the
        // gutter between sections cream instead of the default light gray,
        // without touching each screen individually.
        UITableView.appearance().backgroundColor = cream
    }
}
