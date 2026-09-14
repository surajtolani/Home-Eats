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
func presentAfterMenuDismiss(_ present: @escaping @Sendable () -> Void) {
    // `DispatchQueue.main.asyncAfter(deadline:execute:)`'s `execute` is
    // `@Sendable` (GCD's own concurrency-safety requirement, unrelated to
    // this function's own `@MainActor` isolation) — `present` has to match
    // that or the compiler rejects passing it straight through. Every real
    // call site hands this a closure that only touches `@State`/`Binding`
    // values on the calling View, which is exactly what `@Sendable` is
    // meant to allow here: the closure still only ever actually runs on the
    // main queue (`.main.asyncAfter`), so this doesn't change when or where
    // `present` executes, just satisfies the type-checker about what it's
    // safe to hand across that boundary.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: present)
}
