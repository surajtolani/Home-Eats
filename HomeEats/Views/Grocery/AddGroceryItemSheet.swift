import SwiftUI
import SwiftData

/// Adds a one-off item straight to this week's list — for the "oh, we also
/// need X" case that doesn't belong in a recipe or the standing staples list.
struct AddGroceryItemSheet: View {
    let weekStart: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

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
                    Text("This Week").tag(GroceryListSection.thisWeek)
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
        let item = GroceryItem(
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            section: section,
            quantityText: quantityText,
            weekStartDate: weekStart,
            isManuallyAdded: true
        )
        modelContext.insert(item)
        dismiss()
    }
}
