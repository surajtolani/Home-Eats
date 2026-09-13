import SwiftUI
import SwiftData

/// The group-scoped counterpart of the personal `AislesManagerView` — lets
/// the group define the aisles of their actual grocery store, in walking
/// order, so "My Layout" (`GroupSharedGroceryListView`) can lay the shared
/// shopping list out the same way. Reuses that screen's *visual* language
/// exactly (add row, tap-to-rename, drag-to-reorder, swipe-to-rename)
/// against the new `GroupStoreAisle` SwiftData model instead of the local,
/// personal `StoreAisle` (untouched per this feature's own scope notes).
///
/// **Any member, not MANAGER-only** — see `GroupStoreAisle`'s own doc
/// comment (and routes/groupGroceryAisles.js's) for the full reasoning: an
/// aisle is a display/organization construct, not a decision about what's
/// actually being bought, so nothing in this screen gates on `isManager` at
/// all — every action here (add/rename/reorder/delete) is open to any
/// group member, matching the backend exactly.
///
/// **Local-first**: every action here writes to the local SwiftData store
/// first and returns instantly, whether online or off; `GroupSyncService`
/// pushes/pulls in the background. The first ten rows are usually the
/// starter aisles the backend seeds once per group, mirroring
/// `GroceryCategory` — see `AccountsAPIClient.getGroupGroceryAisles`'s own
/// doc comment for why this screen (and `GroupSharedGroceryListView`'s own
/// sync loop, which calls that same endpoint every cycle) is what makes
/// them already present by the time this screen is opened, rather than
/// starting empty.
struct GroupAislesManagerView: View {
    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var aisles: [GroupStoreAisle]

    @State private var newAisleName = ""
    @State private var renamingAisle: GroupStoreAisle?
    @State private var renameText = ""

    init(groupID: String) {
        self.groupID = groupID
        let gid = groupID
        _aisles = Query(filter: #Predicate<GroupStoreAisle> { $0.groupID == gid })
    }

    /// `.pendingDelete` rows hidden immediately (optimistic), sorted the
    /// same "lowest `sortIndex` first" order as the personal
    /// `@Query(sort: \StoreAisle.sortIndex)` — a plain `.sorted` here rather
    /// than a `@Query` sort descriptor, since the underlying `@Query` above
    /// can't also filter out `.pendingDelete` rows via `#Predicate` (this
    /// codebase's established caution against filtering on a custom enum in
    /// a macro — see `GroupSyncService`'s own comment on this).
    private var visibleAisles: [GroupStoreAisle] {
        aisles.filter { $0.syncState != .pendingDelete }.sorted { $0.sortIndex < $1.sortIndex }
    }

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
                    Text("Add aisles in the order you walk through the store, then use the ⋯ on an item in My Layout to place it there. Anyone in the group can manage aisles.")
                }

                Section {
                    if visibleAisles.isEmpty {
                        Text("No aisles yet.").foregroundStyle(.secondary)
                    }
                    ForEach(visibleAisles) { aisle in
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
                    // `.onDelete` (not a `.swipeActions(role: .destructive)`
                    // button) — same as the personal `AislesManagerView`:
                    // this gives both a swipe-to-delete gesture AND the red
                    // "-" circle once `EditButton()` is tapped, for free.
                    .onDelete { offsets in
                        for index in offsets { delete(visibleAisles[index]) }
                    }
                    .onMove { source, destination in
                        move(source: source, destination: destination)
                    }
                } footer: {
                    Text("Tap an aisle to rename it — including one of the starter aisles already grouping your list by category.")
                }
            }
            .navigationTitle("Group's Store Aisles")
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
        let nextIndex = (visibleAisles.map(\.sortIndex).max() ?? -1) + 1
        modelContext.insert(GroupStoreAisle(
            id: GroupStoreAisle.newLocalPlaceholderID(), groupID: groupID, name: name,
            sortIndex: nextIndex, syncState: .pendingCreate
        ))
        try? modelContext.save()
        triggerSync()
        newAisleName = ""
    }

    /// Renumbers every row to consecutive whole numbers on every drag — same
    /// simple "whole list rewritten at once" approach as the personal
    /// `AislesManagerView.move`, not the fractional between-neighbors scheme
    /// `GroupStoreAisle.sortIndex`'s own doc comment mentions the backend
    /// itself supports; see that comment for why this app's UI never
    /// actually needs the fractional case.
    private func move(source: IndexSet, destination: Int) {
        var reordered = visibleAisles
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, aisle) in reordered.enumerated() where aisle.sortIndex != Double(index) {
            aisle.sortIndex = Double(index)
            markDirtyIfSynced(aisle)
        }
        try? modelContext.save()
        triggerSync()
    }

    private func beginRenaming(_ aisle: GroupStoreAisle) {
        renamingAisle = aisle
        renameText = aisle.name
    }

    private func saveRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let aisle = renamingAisle else { renamingAisle = nil; return }
        aisle.name = trimmed
        markDirtyIfSynced(aisle)
        try? modelContext.save()
        triggerSync()
        renamingAisle = nil
    }

    private func delete(_ aisle: GroupStoreAisle) {
        if aisle.isLocalPlaceholderID {
            modelContext.delete(aisle)
        } else {
            aisle.syncState = .pendingDelete
        }
        try? modelContext.save()
        triggerSync()
    }

    /// Same "don't downgrade a still-`.pendingCreate` row" reasoning as
    /// `GroupSharedGroceryListView.markDirtyIfSynced` — see that method's own
    /// doc comment.
    private func markDirtyIfSynced(_ aisle: GroupStoreAisle) {
        if aisle.syncState == .synced { aisle.syncState = .pendingUpdate }
    }

    /// This sheet has no ongoing periodic sync loop of its own (unlike
    /// `GroupSharedGroceryListView`, which owns one for as long as it's
    /// on-screen) — a fire-and-forget sync after each local write is enough
    /// to get changes out promptly while this sheet is open, and the
    /// underlying screen's own loop (still running underneath this modal)
    /// picks up anything this misses.
    private func triggerSync() {
        Task { _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext) }
    }
}
