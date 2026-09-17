import SwiftUI

/// The one place `MediaTileRow`'s overall height is set — a plain
/// top-level constant, not a `static` member of `MediaTileRow` itself, so
/// every call site can reference it as `mediaTileHeight` without having to
/// spell out an otherwise-irrelevant generic parameter just to name a
/// static property on a generic type (`MediaTileRow<EmptyView>.tileHeight`).
let mediaTileHeight: CGFloat = 64

/// A horizontal media tile — a square thumbnail on the left, a bold title
/// and a secondary meta row (icon + text pairs, e.g. "25 min" / "serves
/// 4") stacked to its right, and an optional circular accent-colored
/// accessory button floating over its top-right corner. Direct user
/// request, modeled on a reference screenshot they attached, for one
/// consistent tile format shared across the Plan tab's calendar view (a
/// decided meal), Restaurants, and Recipes — "This tile should probably be
/// a consistent size and format across all the other tiles" — with a
/// shorter height than their reference image ("although I would make it
/// shorter height"): `tileHeight` below is the one place that height is
/// set, so every call site stays in sync automatically if it's ever
/// tuned.
///
/// Deliberately NOT used for the Plan tab's Weekly agenda list (direct
/// user request: "No need for the tile on the weekly tab" — that list
/// stays `GroupAgendaDayRow`, unchanged) or for a meal *suggestion* row
/// (`GroupSuggestionRow`, which carries its own upvote/downvote/"Use This"
/// controls — the reference tile has room for exactly one accessory
/// action, not three, and retrofitting that carefully-tuned voting UI into
/// this shape risked breaking it without any way to visually verify the
/// result here).
struct MediaTileRow<Thumbnail: View>: View {
    let title: String
    var metaItems: [(icon: String, text: String)] = []
    @ViewBuilder var thumbnail: () -> Thumbnail
    /// The one floating corner action this tile offers, if any — e.g. a
    /// heart (favorite) or a "+" (quick-add). Everything else a card used
    /// to offer inline (share, add-to-library, ...) moves to a swipe
    /// action or a `.contextMenu` at each call site instead of trying to
    /// cram multiple floating badges onto one shorter tile.
    var accessoryIcon: String?
    var accessoryTint: Color = .brandTerracotta
    /// `nil` renders the badge non-interactive (e.g. a plain "already
    /// saved" checkmark) rather than hiding it — only an absent
    /// `accessoryIcon` hides the badge entirely.
    var onAccessoryTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail()
                .frame(width: mediaTileHeight, height: mediaTileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !metaItems.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(metaItems.enumerated()), id: \.offset) { _, item in
                            Label(item.text, systemImage: item.icon)
                        }
                    }
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.brandCream, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            if let accessoryIcon {
                let badge = Image(systemName: accessoryIcon)
                    .font(.brandCallout.bold())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(accessoryTint, in: Circle())

                if let onAccessoryTap {
                    Button(action: onAccessoryTap) { badge }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                } else {
                    badge
                        .allowsHitTesting(false)
                        .offset(x: 6, y: -6)
                }
            }
        }
    }
}
