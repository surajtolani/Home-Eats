import SwiftUI
import SwiftData

/// Adds a one-off item straight to the grocery list — for the "oh, we also
/// need X" case that doesn't belong in a recipe or the standing staples list.
struct AddGroceryItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allGroceryItems: [GroceryItem]
    @Query private var historicalItems: [HistoricalGroceryItem]
    @Query private var allProductOptions: [ProductOption]

    @State private var name = ""
    @State private var quantityText = ""
    @State private var category: GroceryCategory = .other
    @State private var section: GroceryListSection = .thisWeek
    /// Once the user picks a category themselves, stop overwriting it as
    /// they keep typing the name (e.g. fixing a typo would otherwise snap a
    /// manually-chosen category back to the auto-guess).
    @State private var categoryWasChosenManually = false
    /// Set right after `save()` inserts a new item, only when its name
    /// matches a Household Groceries entry that has a noted product — drives
    /// the "use your usual product?" confirmation below. Direct user
    /// request: "if you add something manually... it prompts you to ask if
    /// you want to add the additional details from your household grocery
    /// list." `nil` the rest of the time (the common case: no match, or no
    /// product noted on the match — nothing to ask about).
    @State private var productConfirm: ProductConfirmPrompt?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                TextField("Amount (optional)", text: $quantityText)
                Picker("Category", selection: Binding(
                    get: { category },
                    set: { category = $0; categoryWasChosenManually = true }
                )) {
                    ForEach(GroceryCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(category)
                    }
                }
                Picker("List", selection: $section) {
                    Text("Grocery List").tag(GroceryListSection.thisWeek)
                    Text("Staples").tag(GroceryListSection.staples)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: name) { _, newValue in
                guard !categoryWasChosenManually else { return }
                category = GroceryCategory.guess(fromIngredientName: newValue)
            }
            // Direct user request: "if you add something manually... it
            // prompts you to ask if you want to add the additional details
            // from your household grocery list." Only ever shows when
            // `save()` actually found a match with a noted product — see
            // `productConfirm`'s own doc comment.
            .alert(
                "Use Your Usual Product?",
                isPresented: Binding(get: { productConfirm != nil }, set: { if !$0 { productConfirm = nil } })
            ) {
                Button("Use \(productConfirm?.option.brandName ?? "It")") {
                    productConfirm?.item.selectedProductOptionID = productConfirm?.option.id
                    productConfirm = nil
                    dismiss()
                }
                Button("Not This Time", role: .cancel) {
                    productConfirm = nil
                    dismiss()
                }
            } message: {
                if let productConfirm {
                    Text("You usually get \(productConfirm.option.brandName) for \"\(productConfirm.item.name.titleCasedForDisplay)\". Use that again?")
                }
            }
        }
    }

    private func save() {
        // Lands at the end of both the "By Category" and "My Layout"
        // ordering — without this, a hand-typed item defaults to
        // orderIndex/layoutOrderIndex 0 and jumps to the very top of its
        // category (and of "Unsorted"), ahead of anything already
        // carefully arranged there, which reads exactly like "my reorder
        // didn't stick" the next time an item gets added.
        let purchasable = allGroceryItems.filter { $0.section == .thisWeek || $0.section == .staples }
        let categoryMax = purchasable.filter { $0.category == category }.map(\.orderIndex).max() ?? 0
        let layoutMax = purchasable.map(\.layoutOrderIndex).max() ?? 0
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let item = GroceryItem(
            name: trimmedName,
            category: category,
            section: section,
            quantityText: quantityText,
            isManuallyAdded: true,
            orderIndex: categoryMax + 1,
            layoutOrderIndex: layoutMax + 1
        )
        modelContext.insert(item)
        // If this exact item is already known in Household Groceries with a
        // noted brand, ask before applying it — unlike quick-adding straight
        // FROM a Household Groceries entry (which carries its product over
        // unprompted, since tapping that specific entry already implies
        // "yes, this one"), typing a name here is a much weaker signal that
        // just happens to match, so this confirms first rather than
        // silently attaching a product the user didn't ask for.
        if let matchedOption = matchingProductOption(for: trimmedName) {
            productConfirm = ProductConfirmPrompt(item: item, option: matchedOption)
        } else {
            dismiss()
        }
    }

    private func matchingProductOption(for itemName: String) -> ProductOption? {
        let key = GroceryListBuilder.canonicalKey(for: itemName)
        guard let historyItem = historicalItems.first(where: { GroceryListBuilder.canonicalKey(for: $0.name) == key }),
              let productID = historyItem.preferredProductOptionID else { return nil }
        return allProductOptions.first { $0.id == productID }
    }
}

private struct ProductConfirmPrompt {
    let item: GroceryItem
    let option: ProductOption
}
