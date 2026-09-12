import SwiftUI
import SwiftData

/// Adds a one-off item straight to the grocery list — for the "oh, we also
/// need X" case that doesn't belong in a recipe or the standing staples list.
struct AddGroceryItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allGroceryItems: [GroceryItem]

    @State private var name = ""
    @State private var quantityText = ""
    @State private var category: GroceryCategory = .other
    @State private var section: GroceryListSection = .thisWeek
    /// Once the user picks a category themselves, stop overwriting it as
    /// they keep typing the name (e.g. fixing a typo would otherwise snap a
    /// manually-chosen category back to the auto-guess).
    @State private var categoryWasChosenManually = false

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
        let item = GroceryItem(
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            section: section,
            quantityText: quantityText,
            isManuallyAdded: true,
            orderIndex: categoryMax + 1,
            layoutOrderIndex: layoutMax + 1
        )
        modelContext.insert(item)
        dismiss()
    }
}
