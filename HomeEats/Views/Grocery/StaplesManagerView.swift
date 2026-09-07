import SwiftUI
import SwiftData

/// Manages the household's standing "staples" list — the digital
/// replacement for the notepad on the fridge. Toggling an item off means it
/// won't be included next time a grocery list is generated, without losing
/// it from the household's list entirely.
struct StaplesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StapleItem.name) private var staples: [StapleItem]

    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                if staples.isEmpty {
                    ContentUnavailableView(
                        "No Staples Yet",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Add the regular items your family always needs, like milk or paper towels.")
                    )
                }
                ForEach(staples) { staple in
                    Toggle(isOn: Binding(
                        get: { staple.isActive },
                        set: { staple.isActive = $0 }
                    )) {
                        VStack(alignment: .leading) {
                            Text(staple.name)
                            Text(staple.category.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { modelContext.delete(staples[index]) }
                }
            }
            .navigationTitle("Staples")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddStapleSheet()
            }
        }
    }
}

private struct AddStapleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var category: GroceryCategory = .other
    @State private var quantityText = ""
    /// Once the user picks a category themselves, stop overwriting it as
    /// they keep typing the name.
    @State private var categoryWasChosenManually = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                    .onChange(of: name) { _, newValue in
                        guard !categoryWasChosenManually else { return }
                        category = GroceryCategory.guess(fromIngredientName: newValue)
                    }
                Picker("Category", selection: Binding(
                    get: { category },
                    set: { category = $0; categoryWasChosenManually = true }
                )) {
                    ForEach(GroceryCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(category)
                    }
                }
                TextField("Usual amount (optional)", text: $quantityText)
            }
            .navigationTitle("New Staple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        modelContext.insert(StapleItem(
                            name: name.trimmingCharacters(in: .whitespaces),
                            category: category,
                            defaultQuantityText: quantityText.isEmpty ? nil : quantityText
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
