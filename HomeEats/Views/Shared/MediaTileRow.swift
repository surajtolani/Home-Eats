import SwiftUI

/// The one place `MediaTileRow`'s overall height is set — a plain
/// top-level constant, not a `static` member of `MediaTileRow` itself, so
/// every call site can reference it as `mediaTileHeight` without having to
/// spell out an otherwise-irrelevant generic parameter just to name a
/// static property on a generic type (`MediaTileRow<EmptyView>.tileHeight`).
///
/// Bumped from the original 64 — direct user report: at that size, with a
/// real title/meta/actions combination (a two-word restaurant name, cuisine
/// + price + rating, a favorite star; or a recipe's time + servings + up to
/// four action icons), there wasn't enough room and text was getting cut
/// off outright, not just tightly fit. 92 gives the title room to wrap to a
/// genuine second line (see `title`'s own `.lineLimit(2)` below — also a
/// direct ask: "if the name of restaurant needs to be in 2 lines that's
/// fine") and the meta row room to wrap onto two lines of its own instead
/// of squeezing every item onto one.
let mediaTileHeight: CGFloat = 92

/// One always-visible action icon on a `MediaTileRow`'s trailing edge —
/// a plain top-level type, not nested inside `MediaTileRow` itself, for
/// the same reason `mediaTileHeight` above is a plain top-level constant:
/// it doesn't depend on `MediaTileRow`'s `Thumbnail` generic parameter at
/// all, so nesting it would force every call site to spell out an
/// otherwise-irrelevant concrete type just to name it
/// (`MediaTileRow<EmptyView>.Action(...)`).
struct MediaTileAction {
    let icon: String
    var tint: Color = .brandForest
    /// A bare SF Symbol icon reads as nothing meaningful to VoiceOver on
    /// its own ("star," not "Favorite") — every call site supplies its own
    /// real word here, same as the icons this replaced each already had
    /// via `.accessibilityLabel`/a `Label`'s own text.
    let label: String
    /// `nil` renders this icon plain/non-interactive (e.g. "already
    /// saved") rather than omitting it — only leaving it out of a
    /// `MediaTileRow`'s `actions` array entirely hides it.
    var onTap: (() -> Void)?

    init(icon: String, tint: Color = .brandForest, label: String, onTap: (() -> Void)?) {
        self.icon = icon
        self.tint = tint
        self.label = label
        self.onTap = onTap
    }
}

/// A horizontal media tile — a square thumbnail on the left, a bold title
/// and a secondary meta row (icon + text pairs, e.g. "25 min" / "serves
/// 4") stacked to its right, and a compact row of small, always-visible
/// action icons at its trailing edge. Direct user request, modeled on a
/// reference screenshot they attached, for one consistent tile format
/// shared across the Plan tab's calendar view (a decided meal),
/// Restaurants, and Recipes — "This tile should probably be a consistent
/// size and format across all the other tiles" — with a shorter height
/// than their reference image ("although I would make it shorter
/// height"): `mediaTileHeight` above is the one place that height is set,
/// so every call site stays in sync automatically if it's ever tuned.
///
/// **Every action stays directly on the tile, tappable with no gesture to
/// discover.** An earlier version of this tile moved secondary actions
/// (favorite, share, add-to-library) to swipe actions/a `.contextMenu`,
/// keeping only one as a floating corner badge — direct, immediate
/// follow-up push-back: "Favoriting and sharing and adding to library etc
/// shouldn't be moved to a swipe. It should stay in the tile. I don't want
/// to change functionality, just make it a more seamless and consistent
/// UI across the tabs." `actions` now takes as many icons as a call site
/// actually needs (Restaurants: one, favorite; Recipes: up to four,
/// quick-add/share/add-to-library/favorite; Plan: none), rendered as one
/// small icon-button row, restoring the exact original always-visible,
/// no-swipe-required behavior on top of the new tile shape.
///
/// Deliberately NOT used for the Plan tab's Weekly agenda list (direct
/// user request: "No need for the tile on the weekly tab" — that list
/// stays `GroupAgendaDayRow`, unchanged) or for a meal *suggestion* row
/// (`GroupSuggestionRow`, which carries its own upvote/downvote/"Use This"
/// controls — retrofitting that carefully-tuned voting UI into this shape
/// risked breaking it without any way to visually verify the result here).
struct MediaTileRow<Thumbnail: View>: View {
    let title: String
    var metaItems: [(icon: String, text: String)] = []
    @ViewBuilder var thumbnail: () -> Thumbnail
    var actions: [MediaTileAction] = []

    var body: some View {
        HStack(spacing: 12) {
            thumbnail()
                .frame(width: mediaTileHeight, height: mediaTileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                    // 2 lines, not 1 — direct user request ("if the name of
                    // restaurant needs to be in 2 lines that's fine"), so a
                    // real full name/title is readable instead of ending in
                    // an ellipsis the moment it's longer than a few words.
                    .lineLimit(2)
                if !metaItems.isEmpty {
                    // Wrapped into rows of at most 2 items each, rather than
                    // one long `HStack` every item had to squeeze onto —
                    // direct user report that meta info (a recipe's time/
                    // servings, a restaurant's cuisine/price/rating) was
                    // getting cut off with up to 3-4 items and the actions
                    // column both competing for one line's worth of width.
                    // Capped at 2 per row (not a full wrap-whatever-fits
                    // flow layout) to keep this a plain, predictable VStack
                    // of HStacks rather than a custom `Layout` — with at
                    // most 4 meta items on any tile today, that's at most 2
                    // extra lines, which `mediaTileHeight`'s own bump
                    // already makes room for.
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(metaItemRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 10) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                                    Label(item.text, systemImage: item.icon)
                                }
                            }
                        }
                    }
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            if !actions.isEmpty {
                // Spacing tightened from 14 -> 8 — direct user report that
                // the action icons (up to 4, on a recipe tile) were taking
                // too much of the tile's limited width, crowding out the
                // meta row next to them. The icons themselves keep their
                // existing tap target size (`.brandCallout`, same as
                // before) — only the gap between them shrinks.
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        if let onTap = action.onTap {
                            Button(action: onTap) {
                                Image(systemName: action.icon)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(action.tint)
                            .accessibilityLabel(action.label)
                        } else {
                            Image(systemName: action.icon)
                                .allowsHitTesting(false)
                                .foregroundStyle(action.tint)
                                .accessibilityLabel(action.label)
                        }
                    }
                }
                .font(.brandCallout)
            }
        }
        .padding(10)
        .background(Color.brandCream, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
    }

    /// `metaItems` chunked two at a time, in order — see the call site's
    /// own comment for why a fixed 2-per-row cap instead of a true wrapping
    /// flow layout.
    private var metaItemRows: [[(icon: String, text: String)]] {
        stride(from: 0, to: metaItems.count, by: 2).map { start in
            Array(metaItems[start..<min(start + 2, metaItems.count)])
        }
    }
}
