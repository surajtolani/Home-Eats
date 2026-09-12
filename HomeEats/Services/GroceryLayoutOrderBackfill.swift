import Foundation
import SwiftData

/// One-time migration helper for `GroceryItem.layoutOrderIndex`, added after
/// "My Layout" reordering already existed. SwiftData's lightweight migration
/// silently gives every pre-existing row the field's default (`0`) rather
/// than erroring — which meant every item that existed before this field was
/// introduced tied at `0` in "My Layout," and since `Array.sorted` isn't
/// stable for ties (and the backing `@Query` has no sort descriptor to make
/// its own fetch order deterministic), those tied items could visibly
/// reshuffle between renders for reasons that had nothing to do with an
/// actual drag — reading exactly like "reordering doesn't stick."
///
/// Run once at launch: if every item is still sitting on the shared default,
/// spread them out using their existing `orderIndex` (the "By Category"
/// order) as a reasonable starting layout, so nothing here silently
/// no-ops forever for someone who already has grocery data.
enum GroceryLayoutOrderBackfill {
    @MainActor
    static func runIfNeeded(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<GroceryItem>())) ?? []
        // Only fires when literally nothing has ever been given a real
        // layout position yet — the moment even one item has been dragged
        // in "My Layout" (or added since the fix, landing past 0), this
        // stops matching and never runs again.
        guard items.count > 1, items.allSatisfy({ $0.layoutOrderIndex == 0 }) else { return }
        for (index, item) in items.sorted(by: { $0.orderIndex < $1.orderIndex }).enumerated() {
            item.layoutOrderIndex = Double(index)
        }
    }
}
