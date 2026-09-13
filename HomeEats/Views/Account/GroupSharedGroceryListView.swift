import SwiftUI
import SwiftData

/// A group's shared grocery list — category-grouped, with a suggest/accept
/// flow and check-off, reached from `GroupDetailView`'s "Shared Grocery
/// List" link. A new screen (see this feature's scope notes — the existing
/// personal `GroceryListView` stays untouched); reuses that screen's
/// *visual* language (category sections, a checkbox row, an Accept/Reject-
/// style suggestion row) rebuilt against the new `GroupSharedGroceryItem`
/// SwiftData model. v1 deliberately has no "My Layout" aisle mode here at
/// all — matching the backend, which only supports category-grouped
/// ordering for a group's list (see `GroupSharedGroceryItem`'s own doc
/// comment) — so, unlike `GroceryListView`, there's no view-mode picker at
/// all, just the one "By Category" layout.
///
/// **Local-first / sync**: same design as `GroupSharedMealPlanView` — see
/// that view's and `GroupSyncService`'s own doc comments for the full
/// push/pull/reconcile story, the periodic-resync loop, and the offline
/// indicator's reasoning; not repeated here.
///
/// **Role gating**: mirrors routes/groupGrocery.js's field-by-field split
/// exactly — any member can check an item off or reorder it (routine,
/// day-to-day list use); only a `MANAGER` can add an item straight onto the
/// real list, edit its name/category/quantity/section, or accept a
/// suggestion; a `PARTICIPANT` can only suggest (create with
/// `section: .suggested`) and can remove their own suggestion (or any
/// `THIS_WEEK`/`STAPLES` item — routine maintenance, open to anyone).
struct GroupSharedGroceryListView: View {
    let groupID: String
    let groupName: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @Query private var items: [GroupSharedGroceryItem]

    @State private var group: GroupDetail?
    @State private var lastSyncOutcome: GroupSyncService.SyncOutcome?
    @State private var showAddSheet = false
    @State private var editingItem: GroupSharedGroceryItem?
    @State private var actionErrorMessage: String?

    init(groupID: String, groupName: String) {
        self.groupID = groupID
        self.groupName = groupName
        // Same captured-local-constant `#Predicate` caution as
        // `GroupSharedMealPlanView.init` — see its own comment.
        let gid = groupID
        _items = Query(filter: #Predicate<GroupSharedGroceryItem> { $0.groupID == gid })
    }

    private var myRole: GroupRole? { group?.myRole(currentUserID: accountSession.currentUser?.id) }
    private var isManager: Bool { myRole == .manager }

    private var hasPendingChanges: Bool { items.contains { $0.syncState != .synced } }

    private var isKnownOffline: Bool {
        guard let lastSyncOutcome else { return false }
        return !lastSyncOutcome.pullSucceeded
    }

    /// Every `@Query` row below reads through this, not `items` directly —
    /// same "optimistically hide a `.pendingDelete` row rather than leave it
    /// fully visible until the next successful push" reasoning as
    /// `GroupSharedMealPlanView.visiblePlannedMeals`; see that property's
    /// own doc comment.
    private var visibleItems: [GroupSharedGroceryItem] {
        items.filter { $0.syncState != .pendingDelete }
    }

    private var suggestedItems: [GroupSharedGroceryItem] {
        visibleItems.filter { $0.section == .suggested }.sorted { $0.name < $1.name }
    }

    private var purchasableItems: [GroupSharedGroceryItem] {
        visibleItems.filter { $0.section == .thisWeek || $0.section == .staples }
    }

    private var purchasableByCategory: [(GroceryCategory, [GroupSharedGroceryItem])] {
        Dictionary(grouping: purchasableItems, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { ($0.key, $0.value.sorted(by: orderIndexIsBefore)) }
    }

    /// Same tie-breaking-by-id reasoning as `GroceryListView.orderIndexIsBefore`
    /// — every never-manually-reordered item defaults to `orderIndex == 0`,
    /// so falling back to `id` keeps ties from visibly swapping places
    /// across re-renders for no real reason.
    private func orderIndexIsBefore(_ lhs: GroupSharedGroceryItem, _ rhs: GroupSharedGroceryItem) -> Bool {
        lhs.orderIndex != rhs.orderIndex ? lhs.orderIndex < rhs.orderIndex : lhs.id < rhs.id
    }

    var body: some View {
        List {
            if hasPendingChanges || isKnownOffline {
                Section {
                    Label(statusMessage, systemImage: "wifi.slash")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }

            if !suggestedItems.isEmpty {
                Section {
                    ForEach(suggestedItems) { item in
                        suggestedRow(item)
                    }
                } header: {
                    Text("Suggested")
                } footer: {
                    Text(isManager
                        ? "Accept to move it onto the real list, or remove it to reject."
                        : "A manager will review these — you can still remove your own suggestion.")
                }
            }

            if purchasableByCategory.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing on the List Yet",
                        systemImage: "cart",
                        description: Text(isManager
                            ? "Tap + to add the first item."
                            : "Tap + to suggest the first item — a manager can add it once they review it.")
                    )
                }
            } else {
                ForEach(Array(purchasableByCategory.enumerated()), id: \.element.0) { _, entry in
                    let (category, categoryItems) = entry
                    Section {
                        ForEach(categoryItems) { item in
                            purchasableRow(item)
                        }
                        .onMove { source, destination in
                            reorder(categoryItems, from: source, to: destination)
                        }
                    } header: {
                        Text(category.displayName)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .task {
            await loadGroup()
            await runSync()
            await runPeriodicSyncLoop()
        }
        .refreshable { await runSync() }
        .sheet(isPresented: $showAddSheet) {
            AddGroupGroceryItemSheet(groupID: groupID, isManager: isManager)
        }
        .sheet(item: $editingItem) { item in
            EditGroupGroceryItemSheet(groupID: groupID, item: item) { errorMessage in
                actionErrorMessage = errorMessage
            }
        }
        .alert(
            "Couldn't complete that",
            isPresented: Binding(get: { actionErrorMessage != nil }, set: { if !$0 { actionErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private var statusMessage: String {
        if hasPendingChanges {
            return "Some changes haven't synced yet — they'll go out automatically once you're back online."
        }
        return "Couldn't reach the server — showing what was last synced."
    }

    // MARK: - Rows

    @ViewBuilder
    private func suggestedRow(_ item: GroupSharedGroceryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name.titleCasedForDisplay)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText).font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.syncState != .synced { pendingIndicator }
            if isManager {
                Button {
                    Task { await accept(item) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandForest)
                .disabled(isKnownOffline || item.isLocalPlaceholderID)
            }
        }
        .swipeActions(edge: .trailing) {
            // MANAGER, or the item's own original suggester — mirrors
            // `DELETE .../grocery/:id` on a `SUGGESTED` item exactly (see
            // routes/groupGrocery.js's own doc comment on that route).
            if isManager || item.addedByUserID == accountSession.currentUser?.id {
                Button(role: .destructive) { delete(item) } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func purchasableRow(_ item: GroupSharedGroceryItem) -> some View {
        HStack {
            // Checking an item off is open to any member — mirrors
            // `PATCH .../grocery/:id`'s `isChecked` field, which has no role
            // gate at all (see routes/groupGrocery.js's field-by-field
            // split).
            Button { setChecked(item, !item.isChecked) } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isChecked ? Color.brandForest : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name.titleCasedForDisplay)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText).font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.syncState != .synced { pendingIndicator }
            // Renaming/recategorizing/changing quantity or section is
            // MANAGER only — mirrors `PATCH .../grocery/:id`'s manager-only
            // fields exactly. Deliberately NOT also disabled for a still-
            // `.pendingCreate` row the way the suggestion-accept and
            // meal-plan-adopt buttons are: a manager editing an item they
            // just added, before it's synced, is a normal thing to want to
            // do (fixing a typo) — `EditGroupGroceryItemSheet.save()` itself
            // branches on `isLocalPlaceholderID` to apply that edit locally
            // instead of sending a network `PATCH` against an id the server
            // has never seen.
            if isManager {
                Button { editingItem = item } label: {
                    Image(systemName: "pencil.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            // THIS_WEEK/STAPLES: any member may delete — routine
            // maintenance ("we bought it"/"we don't need it"), mirrors
            // `DELETE .../grocery/:id` on a non-suggested item exactly.
            Button(role: .destructive) { delete(item) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var pendingIndicator: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.brandCaption2)
            .foregroundStyle(.secondary)
            .help("Not synced yet")
    }

    // MARK: - Actions

    private func loadGroup() async {
        group = try? await AccountsAPIClient.getGroup(id: groupID)
    }

    private func runSync() async {
        lastSyncOutcome = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext)
    }

    /// Same "plain `Task.sleep` loop, cancelled automatically on
    /// disappear" design as `GroupSharedMealPlanView.runPeriodicSyncLoop` —
    /// see its own doc comment.
    private func runPeriodicSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            await runSync()
        }
    }

    private func setChecked(_ item: GroupSharedGroceryItem, _ checked: Bool) {
        item.isChecked = checked
        markDirtyIfSynced(item)
        try? modelContext.save()
        Task { await runSync() }
    }

    /// Every category's whole order is rewritten on a same-category
    /// reorder — same simple, whole-category-at-once approach as
    /// `GroceryListView.moveWithinCategory` — rather than fractionally
    /// slotting just the moved item in.
    private func reorder(_ categoryItems: [GroupSharedGroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = categoryItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
            markDirtyIfSynced(item)
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    /// Marks a row as needing a push only if it was previously fully
    /// `.synced` — a row that's still `.pendingCreate` (never yet reached
    /// the server) simply keeps that state with its updated value baked in,
    /// rather than being incorrectly downgraded to `.pendingUpdate` (which
    /// would try to `PATCH` a row the server doesn't know about yet). See
    /// `GroupSyncState`'s own doc comment for the state machine this keeps
    /// consistent with.
    private func markDirtyIfSynced(_ item: GroupSharedGroceryItem) {
        if item.syncState == .synced { item.syncState = .pendingUpdate }
    }

    private func delete(_ item: GroupSharedGroceryItem) {
        if item.isLocalPlaceholderID {
            modelContext.delete(item)
        } else {
            item.syncState = .pendingDelete
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    private func accept(_ item: GroupSharedGroceryItem) async {
        do {
            try await GroupSyncService.acceptGroceryItem(groupID: groupID, itemID: item.id, modelContext: modelContext)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Add an item

/// The "Add"/"Suggest an Item" sheet. A `MANAGER` picks a section
/// (defaulting to "This Week" — the direct-add path); a `PARTICIPANT` has
/// no section picker at all and always creates a `.suggested` item — the
/// UI-level mirror of the backend rejecting any other section from a
/// `PARTICIPANT` outright (see `POST /groups/:groupId/grocery`'s own doc
/// comment in routes/groupGrocery.js). Inserts a `.pendingCreate` row and
/// dismisses immediately, same offline-first pattern as
/// `AddGroupMealSheet`.
private struct AddGroupGroceryItemSheet: View {
    let groupID: String
    let isManager: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var accountSession: AccountSession

    @State private var name = ""
    @State private var category: GroceryCategory = .other
    @State private var quantityText = ""
    @State private var section: GroupGrocerySection = .thisWeek

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && accountSession.currentUser != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Item name", text: $name)
                    TextField("Quantity (optional)", text: $quantityText)
                    Picker("Category", selection: $category) {
                        ForEach(GroceryCategory.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    if isManager {
                        Picker("Section", selection: $section) {
                            ForEach(GroupGrocerySection.allCases) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                    }
                } footer: {
                    if !isManager {
                        Text("This goes into Suggested for a manager to review.")
                    }
                }
            }
            .navigationTitle(isManager ? "Add Item" : "Suggest Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }.disabled(!canSubmit)
                }
            }
        }
    }

    private func submit() {
        guard let currentUserID = accountSession.currentUser?.id else { return }
        let item = GroupSharedGroceryItem(
            id: GroupSharedGroceryItem.newLocalPlaceholderID(),
            groupID: groupID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            // A PARTICIPANT never sees the section picker above, so this
            // always resolves to `.suggested` for them regardless of
            // `section`'s default — matching the backend rule outright
            // rather than merely hiding the control.
            section: isManager ? section : .suggested,
            quantityText: quantityText.trimmingCharacters(in: .whitespacesAndNewlines),
            addedByUserID: currentUserID,
            syncState: .pendingCreate
        )
        modelContext.insert(item)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Edit an item (manager only)

/// Manager-only rename/recategorize/quantity/section edit — deliberately an
/// immediate, online-only call (`GroupSyncService.editGroceryItem`), not a
/// locally-queued `.pendingUpdate` — see `GroupSharedGroceryItem.syncState`'s
/// own doc comment for why.
private struct EditGroupGroceryItemSheet: View {
    let groupID: String
    let item: GroupSharedGroceryItem
    let onError: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var category: GroceryCategory
    @State private var quantityText: String
    @State private var section: GroupGrocerySection
    @State private var isSaving = false

    init(groupID: String, item: GroupSharedGroceryItem, onError: @escaping (String) -> Void) {
        self.groupID = groupID
        self.item = item
        self.onError = onError
        _name = State(initialValue: item.name)
        _category = State(initialValue: item.category)
        _quantityText = State(initialValue: item.quantityText)
        _section = State(initialValue: item.section)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                TextField("Quantity", text: $quantityText)
                Picker("Category", selection: $category) {
                    ForEach(GroceryCategory.allCases) { c in Text(c.displayName).tag(c) }
                }
                Picker("Section", selection: $section) {
                    ForEach(GroupGrocerySection.allCases) { s in Text(s.displayName).tag(s) }
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuantity = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Still `.pendingCreate` (no real server id yet — see
        // `isLocalPlaceholderID`'s doc comment) -> there is no server row
        // for a `PATCH` to target; sending one anyway would 404 and the
        // edit would be silently lost. Apply it directly to the local row
        // instead and leave `syncState` as `.pendingCreate`: its eventual
        // `push()` sends these corrected values as part of the still-
        // pending create call, not as a separate update. This is what lets
        // someone fix a typo in something they just added seconds ago,
        // before it's synced, without the edit vanishing.
        if item.isLocalPlaceholderID {
            item.name = trimmedName
            item.category = category
            item.quantityText = trimmedQuantity
            item.section = section
            try? modelContext.save()
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await GroupSyncService.editGroceryItem(
                groupID: groupID, itemID: item.id,
                name: trimmedName,
                category: category,
                quantityText: trimmedQuantity,
                section: section,
                modelContext: modelContext
            )
            dismiss()
        } catch {
            onError(error.localizedDescription)
            dismiss()
        }
    }
}
