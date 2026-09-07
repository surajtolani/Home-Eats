import SwiftUI
import SwiftData

/// Lets the household define the aisles of their actual grocery store, in
/// walking order, so "My Grocery Layout" can lay the shopping list out the
/// same way. Reorder with the standard edit-mode drag handles.
struct AislesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoreAisle.sortIndex) private var aisles: [StoreAisle]

    @State private var newAisleName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("e.g. \"Aisle 3 – Snacks\"", text: $newAisleName)
                        Button("Add") { addAisle() }
                            .disabled(newAisleName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Add aisles in the order you walk through the store, then drag items onto them from My Grocery Layout.")
                }

                Section {
                    if aisles.isEmpty {
                        Text("No aisles yet.").foregroundStyle(.secondary)
                    }
                    ForEach(aisles) { aisle in
                        Text(aisle.name)
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(aisles[index]) }
                    }
                    .onMove { source, destination in
                        move(source: source, destination: destination)
                    }
                }
            }
            .navigationTitle("My Store's Aisles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    EditButton()
                }
            }
        }
    }

    private func addAisle() {
        let name = newAisleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let nextIndex = (aisles.map(\.sortIndex).max() ?? -1) + 1
        modelContext.insert(StoreAisle(name: name, sortIndex: nextIndex))
        newAisleName = ""
    }

    private func move(source: IndexSet, destination: Int) {
        var reordered = aisles
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, aisle) in reordered.enumerated() {
            aisle.sortIndex = index
        }
    }
}
