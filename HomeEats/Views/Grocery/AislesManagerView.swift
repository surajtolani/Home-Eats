import SwiftUI
import SwiftData

/// Lets the household define the aisles of their actual grocery store, in
/// walking order, so "My Grocery Layout" can lay the shopping list out the
/// same way. Reorder with the standard edit-mode drag handles.
///
/// The first ten rows here are usually the starter aisles
/// `SampleDataSeeder` seeds one-time to mirror `GroceryCategory` ("Produce",
/// "Dairy & Eggs", ...) — they're what "My Layout" defaults every item into
/// automatically (see `GroceryListView.resolvedAisleID`), rather than
/// everything piling up in "Unsorted." They're ordinary `StoreAisle` rows
/// like any other: renaming, reordering, or deleting one here works exactly
/// the same as for a fully custom aisle typed in below.
struct AislesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoreAisle.sortIndex) private var aisles: [StoreAisle]

    @State private var newAisleName = ""
    @State private var renamingAisle: StoreAisle?
    @State private var renameText = ""

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
                    Text("Add aisles in the order you walk through the store, then use the ⋯ on an item in My Grocery Layout to place it there.")
                }

                Section {
                    if aisles.isEmpty {
                        Text("No aisles yet.").foregroundStyle(.secondary)
                    }
                    ForEach(aisles) { aisle in
                        HStack {
                            Text(aisle.name)
                            if aisle.linkedCategory != nil {
                                Spacer()
                                Text("Category")
                                    .font(.brandCaption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginRenaming(aisle) }
                        .swipeActions(edge: .trailing) {
                            Button("Rename") { beginRenaming(aisle) }
                                .tint(.brandForest)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(aisles[index]) }
                    }
                    .onMove { source, destination in
                        move(source: source, destination: destination)
                    }
                } footer: {
                    Text("Tap an aisle to rename it — including one of the starter aisles already grouping your list by category.")
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
            .alert("Rename Aisle", isPresented: Binding(
                get: { renamingAisle != nil },
                set: { isPresented in if !isPresented { renamingAisle = nil } }
            )) {
                TextField("Aisle name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingAisle = nil }
                Button("Save") { saveRename() }
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func beginRenaming(_ aisle: StoreAisle) {
        renamingAisle = aisle
        renameText = aisle.name
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let aisle = renamingAisle else { renamingAisle = nil; return }
        aisle.name = trimmed
        renamingAisle = nil
    }
}
