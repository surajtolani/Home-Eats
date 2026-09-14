import Foundation

/// Setting `@State` that drives a `.sheet`/`.fullScreenCover` directly inside
/// a `Menu`'s `Button` action races that Menu's own dismissal animation —
/// SwiftUI can end up starting the sheet's presentation transaction while the
/// menu's closing transaction is still in flight, which frequently loses:
/// the sheet flashes on screen for a frame and is immediately torn back down
/// along with the menu, resetting the `@State` back to its initial value.
/// Tapping the same menu item again then works fine, because that second
/// time there's no competing menu-dismissal transaction to race against —
/// which is exactly the "it pops up and disappears, then works the second
/// time" symptom this fixes.
///
/// The workaround (a small, well-known one for this exact SwiftUI/UIKit
/// interaction) is to defer the state change to the next run loop turn,
/// after the menu's own dismissal has already been queued/started, rather
/// than mutating state synchronously inside the button's action.
///
/// Use this for every `Menu`'s `Button` action that sets state feeding a
/// `.sheet`/`.fullScreenCover`/`.sheet(item:)` — plain (non-Menu) buttons
/// don't need it.
@MainActor
func presentAfterMenuDismiss(_ present: @escaping () -> Void) {
    // Previously `DispatchQueue.main.asyncAfter(deadline:execute:)` — its
    // `execute` parameter is `@Sendable` (a GCD API constraint, unrelated to
    // this function's own `@MainActor` isolation), which two earlier fix
    // attempts here chased in the wrong direction: marking `present` itself
    // `@Sendable` satisfied that one call, but every real call site's
    // closure mutates a `@MainActor`-isolated `@State` property
    // (`showAislesManager = true`, `activeSheet = .suggestRecipe(slot)`,
    // ...) — which a `@Sendable` closure is never allowed to do, since
    // `@Sendable` means "might run on any actor," and mutating another
    // actor's isolated state from just anywhere is exactly what actor
    // isolation exists to prevent. That's not a hoop to jump through, it's
    // a real signal the GCD-based delay was the wrong tool here.
    //
    // `Task { @MainActor in ... }` sidesteps this entirely: created from an
    // already-`@MainActor`-isolated function, its closure inherits that
    // same isolation (`Task.init`'s operation parameter is
    // `@_inheritActorContext`), so it can capture and mutate `present` —
    // and whatever `@State` `present` itself mutates — without requiring
    // `@Sendable` at all. `Task.sleep` is the structured-concurrency
    // equivalent of `asyncAfter`'s delay, staying on the main actor the
    // entire time (never hopping to a background queue the way GCD's
    // `.main.asyncAfter` conceptually schedules through), which is if
    // anything a tighter fit for "defer to the next run loop turn after the
    // menu's own dismissal" than the dispatch-queue version ever was.
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 350_000_000)
        present()
    }
}
