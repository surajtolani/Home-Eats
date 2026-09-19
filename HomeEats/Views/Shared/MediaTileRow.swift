import SwiftUI

/// The one place `MediaTileRow`'s overall height is set — a plain
/// top-level constant, not a `static` member of `MediaTileRow` itself, so
/// every call site can reference it as `mediaTileHeight` without having to
/// spell out an otherwise-irrelevant generic parameter just to name a
/// static property on a generic type (`MediaTileRow<EmptyView>.tileHeight`).
///
/// Bumped from an original 64, then again from 92 — direct, repeated user
/// report that even after the first bump, a real title/meta/actions
/// combination (a two-word restaurant name, cuisine + price + rating, a
/// favorite star; or a recipe's time + servings + source + up to four
/// action icons) still ran out of room. 108 gives the title room to wrap to
/// a genuine second line (see `title`'s own `.lineLimit(2)` below — also a
/// direct ask: "if the name of restaurant needs to be in 2 lines that's
/// fine"), the meta rows room for two lines of their own, and the action
/// icons (now their own row underneath those — see `body`) room to sit
/// below the source line without the tile growing much taller.
let mediaTileHeight: CGFloat = 108

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

/// A horizontal media tile — a square thumbnail on the left, and to its
/// right a bold title, a secondary meta row (icon + text pairs, e.g. "25
/// min" / "serves 4"), and a final row of small, always-visible action
/// icons underneath. Direct user request, modeled on a reference
/// screenshot they attached, for one consistent tile format shared across
/// the Plan tab's calendar view (a decided meal), Restaurants, and Recipes
/// — "This tile should probably be a consistent size and format across all
/// the other tiles" — with a shorter height than their reference image
/// ("although I would make it shorter height"): `mediaTileHeight` above is
/// the one place that height is set, so every call site stays in sync
/// automatically if it's ever tuned.
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
/// **Two or more actions sit in their own row below the meta info; exactly
/// one stays as a corner icon instead.** Direct, repeated report that a
/// recipe's title and meta info (time, servings, source) were still
/// getting cut off even after the tile grew taller — first traced to a
/// horizontal row of up to four action icons eating most of the tile's
/// width next to the title, then (after moving the icons to a trailing
/// vertical column) to a direct follow-up ask to try tucking them under
/// the meta info entirely instead. That fixed it for Recipes' up-to-four
/// icons, but a direct follow-up specifically about Restaurants' *single*
/// favorite star ("if just the star, then that can maybe stay where it
/// was") pointed out a single icon doesn't need — and reads oddly getting
/// — a whole extra row to itself underneath cuisine/price/rating. So
/// `actions.count > 1` renders the row-below-meta layout (Recipes); a lone
/// action instead renders where it always has, a small icon at the tile's
/// trailing edge (Restaurants' star) — still always-visible and directly
/// tappable, just not consuming a whole row for one glyph. Either way, the
/// title/meta column claims the tile's remaining width via
/// `.frame(maxWidth: .infinity)` below rather than sharing it with a
/// `Spacer`, so the title runs to the right edge and only wraps to a
/// second line if it genuinely needs to.
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
        HStack(alignment: .top, spacing: 12) {
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
                    // getting cut off with up to 3-4 items competing for one
                    // line's worth of width. Capped at 2 per row (not a full
                    // wrap-whatever-fits flow layout) to keep this a plain,
                    // predictable VStack of HStacks rather than a custom
                    // `Layout` — with at most 4 meta items on any tile
                    // today, that's at most 2 rows, which naturally reads
                    // as "time + servings" then "source" underneath it for
                    // a recipe (see `RecipesHomeView.recipeMetaItems`),
                    // which is exactly the requested order.
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

                if actions.count > 1 {
                    // One more row under the meta info, not off to the
                    // trailing edge — see this type's own doc comment. Only
                    // for 2+ actions (Recipes); a single action (e.g.
                    // Restaurants' favorite star) renders at the tile's
                    // trailing edge instead, below. Left-aligned like
                    // everything else in this column, rather than spread
                    // out, so it reads as a compact row of icons rather
                    // than a second action bar.
                    HStack(spacing: 14) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            actionButton(action)
                        }
                    }
                    .font(.brandCallout)
                    .padding(.top, 2)
                }
            }
            // Claims the tile's remaining width. Nothing else shares this
            // row when there are 2+ actions (they moved into their own row
            // inside this column, above); a single action still sits
            // trailing this column, below — see this type's own doc
            // comment for why that one case is different.
            .frame(maxWidth: .infinity, alignment: .leading)

            if actions.count == 1 {
                actionButton(actions[0])
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

    /// One action icon, shared by both places it can render (the
    /// row-below-meta layout for 2+ actions, and the single trailing icon
    /// for exactly 1) so the tappable/non-tappable and tint/label handling
    /// only lives in one place.
    @ViewBuilder
    private func actionButton(_ action: MediaTileAction) -> some View {
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
