import SwiftUI

/// A floating "some changes haven't synced yet"/"couldn't reach the
/// server" banner — shared by every group screen that has one
/// (`GroupSharedMealPlanView`, `GroupSharedGroceryListView`), so this
/// exact bug/policy only ever needs fixing in one place.
///
/// **Why this exists as a standalone type at all, rather than each screen
/// just writing its own `Label(...)`**: both screens used to show this as
/// a plain row that got conditionally inserted into/removed from their own
/// layout (a `VStack` row in the meal plan screen, a `List` `Section` in
/// the grocery screen) — and since a vote, a checkbox tap, or a quantity
/// bump all briefly flip a row to `.pendingUpdate` before the immediate
/// follow-up sync clears it again (well under a second later), that row
/// was popping in and back out on nearly every single interaction,
/// visibly shifting every bit of content below it down and back up — a
/// real, repeatedly reported "the screen jumps/skips" bug. Disabling the
/// implicit insertion animation on the meal plan screen wasn't enough on
/// its own: even an instant, unanimated layout change still visibly jumps
/// content by exactly the banner's height for that brief window.
///
/// The actual fix, applied via `.syncStatusOverlay(isVisible:message:)`
/// below: this is a true floating overlay, composited on top of a
/// screen's content rather than occupying space that content's own layout
/// accounts for — so it can never shift anything else on screen, no
/// matter how often it flickers.
struct SyncStatusBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "wifi.slash")
            .font(.brandCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

extension View {
    /// Floats a `SyncStatusBanner(message:)` over the **bottom** of `self`
    /// while `isVisible`, without ever affecting `self`'s own layout — see
    /// `SyncStatusBanner`'s own doc comment for the bug this fixes.
    ///
    /// Bottom, not top: direct user request ("move that notification to
    /// the bottom of the page everywhere it shows up so it doesn't impact
    /// how the pages are viewed") — the top of these screens is exactly
    /// where a glance lands first (the day header, the quick-add field,
    /// the view-mode picker), so floating a transient sync status there,
    /// even non-layout-shifting, still visually competed with that
    /// content; the bottom is out of the way of all of it.
    ///
    /// `.allowsHitTesting(false)` on the banner itself: purely
    /// informational, so it never intercepts a tap meant for whatever
    /// content it's momentarily floating over.
    @ViewBuilder
    func syncStatusOverlay(isVisible: Bool, message: String) -> some View {
        self
            // A permanent bit of clearance below the last row of real
            // content — NOT conditional on `isVisible` (unlike the overlay
            // itself just below), so this reservation can never itself
            // pop in/out and reintroduce the exact "screen jumps on every
            // vote" bug this type's own doc comment describes. Direct user
            // report: even as a non-layout-shifting overlay, the banner
            // could still visually sit right on top of the last row of
            // real content while it was showing — especially bad
            // somewhere it can stay up 15-30 seconds on a slow connection
            // (poor reception) rather than flash briefly. This gap is
            // sized for the banner's own height (see `SyncStatusBanner`'s
            // font/padding) with a little extra breathing room, and
            // works because a `List`/`ScrollView` inside `self`
            // automatically insets its own scrollable content to stay
            // clear of a `.safeAreaInset` applied to an ancestor, the same
            // way it would for a custom tab bar.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 36)
            }
            .overlay(alignment: .bottom) {
                if isVisible {
                    SyncStatusBanner(message: message)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isVisible)
    }
}
