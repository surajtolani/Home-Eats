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
/// pushes/pulls in the background. A brand-new group starts with zero
/// aisles here — direct user request that My Layout read as a blank
/// notepad, not pre-grouped by category — so "No aisles yet" is the normal
/// first-open state; a group seeded with the old ten category-mirroring
/// starter aisles before that behavior was removed keeps them until
/// someone deletes them (one at a time via swipe/drag-to-delete, or all at
/// once via `removeStarterAisles()` below — a direct fix for exactly that
/// migration case).
///
/// **Reorder/delete handles are always visible** (`editMode` permanently
/// `.active`, same "real writable binding, not `.constant`" pattern as
/// `GroupSharedGroceryListView.editMode`) — direct user report that this
/// screen used to hide them behind a tap on "Edit" first, with nothing on
/// screen hinting that was necessary: "there is no way to know it's
/// movable" without already knowing to look for an Edit button.
struct GroupAislesManagerView: View {
    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var aisles: [GroupStoreAisle]

    @State private var newAisleName = ""
    @State private var renamingAisle: GroupStoreAisle?
    @State private var renameText = ""
    @State private var editMode: EditMode = .active

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

    /// Whether this group still has any of the old default-seeded starter
    /// aisles (`linkedCategory != nil` — see this type's own top doc
    /// comment) — drives the one-tap "Remove Starter Aisles" cleanup
    /// section below, hidden entirely for a group that never had them (a
    /// brand-new one) or has already deleted them all.
    private var hasStarterAisles: Bool {
        visibleAisles.contains { $0.linkedCategory != nil }
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
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }

                if hasStarterAisles {
                    Section {
                        Button(role: .destructive) {
                            removeStarterAisles()
                        } label: {
                            Text("Remove Starter Aisles")
                        }
                    } footer: {
                        Text("This group still has aisles from an older version of My Layout that grouped everything by category automatically. Remove them to start with a blank layout — anything in one moves to Unsorted.")
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
                    }
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
                    .onDelete { offsets in
                        for index in offsets { delete(visibleAisles[index]) }
                    }
                    .onMove { source, destination in
                        move(source: source, destination: destination)
                    }
                } header: {
                    Text("Your Sections")
                } footer: {
                    Text("Drag the ≡ handle to reorder, swipe to delete, or tap a name to rename it.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Group's Store Aisles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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

    /// One-tap cleanup for a group that still has the old default-seeded
    /// starter aisles — direct fix for a real report that a group already
    /// seeded before that behavior was removed still looked pre-grouped by
    /// category, with no easy way to clear it short of deleting ten rows
    /// one at a time. Deletes every remaining `linkedCategory != nil`
    /// aisle the same way swiping one away does (`delete(_:)`, so any item
    /// placed in one falls back to "Unsorted" the identical way a single
    /// delete already does — see that field's own doc comment in
    /// prisma/schema.prisma) — one `Task`, one `triggerSync()` call at the
    /// end rather than one per row, so this doesn't fire a dozen redundant
    /// syncs back to back.
    private func removeStarterAisles() {
        for aisle in visibleAisles where aisle.linkedCategory != nil {
            if aisle.isLocalPlaceholderID {
                modelContext.delete(aisle)
            } else {
                aisle.syncState = .pendingDelete
            }
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
