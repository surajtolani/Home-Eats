import SwiftData

/// One-time migration: `reject(_:)` on the grocery list used to set
/// `item.section = .rejected` and keep the row around forever, rather than
/// deleting it — meaning rejecting an ingredient once ("I already have
/// flour") permanently blocked that same ingredient from ever being
/// suggested again for any future planned meal, since
/// `GroceryListBuilder.regenerate` treated an existing `.rejected` row as an
/// already-made decision and just refreshed it in place instead of
/// re-suggesting it. Rejecting now deletes the row outright instead, so
/// nothing new will ever land in `.rejected` — but anyone who rejected
/// something before this fix still has it sitting there, silently blocking
/// that ingredient. Deleting any leftover `.rejected` rows at launch clears
/// that out; a completely safe no-op for anyone who never had one.
enum RejectedGroceryItemCleanup {
    @MainActor
    static func runIfNeeded(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<GroceryItem>())) ?? []
        for item in items where item.section == .rejected {
            context.delete(item)
        }
    }
}
