import SwiftUI
import SwiftData

private enum GroupGroceryViewMode: String, CaseIterable, Identifiable {
    case byCategory = "By Category"
    case myLayout = "My Layout"
    var id: String { rawValue }
}

/// A single group's own grocery list — scoped to one `groupID` (never
/// shared across groups; each group has its own independent list). This is
/// what the main "Grocery" tab shows for whichever group is currently
/// active (see `GroupScopedGroceryTab` in RootView.swift), and is also
/// reachable directly from `GroupDetailView`'s "Grocery List" link for a
/// non-active group.
///
/// **Ports the personal `GroceryListView`'s full visual/interaction design**
/// (see that file's own doc comment — it stays untouched, personal/
/// local-only reference view per this feature's scope) onto the
/// group-scoped, offline-capable, backend-synced `GroupSharedGroceryItem`
/// model: a **By Category / My Layout** view-mode toggle, drag-to-reorder,
/// a "Suggested" section, and a "From Your Past Groceries" section — the
/// same three pieces of on-screen structure as the personal reference (its
/// own view-mode picker plus those same two collapsible sections below it),
/// now Phase-4-backed by the group-scoped `GroupStoreAisle`/
/// `GroupGroceryHistoryEntry` models instead of the local `StoreAisle`/
/// `HistoricalGroceryItem`. "Staples" is a separate standing *template* list
/// (`GroupStaplesManagerView`, reachable from the toolbar), not a third view
/// mode — matching the personal app's own structure exactly (see
/// `StapleItem`'s doc comment: a staple is added onto the real list by hand,
/// same as any other item, with `section: .staples`; the standing list is
/// just where its name/category/usual-quantity are remembered for next
/// time). One thing this version deliberately does NOT port: the personal
/// screen's "Paste an Old Grocery List" bulk-import sheet
/// (`GroceryHistoryImportSheet`) — there is no group-scoped bulk-import
/// endpoint on the backend, so this group's past-groceries catalog can only
/// ever grow the automatic way (checking an item off), never by pasting a
/// list; see this feature's own final report.
///
/// **Local-first / sync**: same design as `GroupSharedMealPlanView` — see
/// that view's and `GroupSyncService`'s own doc comments for the full
/// push/pull/reconcile story, the periodic-resync loop, and the offline
/// indicator's reasoning; not repeated here.
///
/// **Role gating**: mirrors routes/groupGrocery.js's field-by-field split
/// exactly — any member can check an item off, reorder it, or move it to a
/// different aisle in "My Layout" (all three are `isChecked`/`orderIndex`/
/// `aisleId`, the "routine, day-to-day use" bucket that field-by-field split
/// draws on — see routes/groupGrocery.js's own doc comment on its PATCH
/// route); only a `MANAGER` can add an item straight onto the real list,
/// edit its name/category/quantity/section, or accept a suggestion; a
/// `PARTICIPANT` can only suggest (create with `section: .suggested`) and
/// can remove their own suggestion (or any `THIS_WEEK`/`STAPLES` item —
/// routine maintenance, open to anyone). Managing "My Layout" aisles and the
/// standing staples list is open to any member too — see
/// `GroupAislesManagerView`/`GroupStaplesManagerView`'s own doc comments.
struct GroupSharedGroceryListView: View {
    let groupID: String
    let groupName: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @Query private var items: [GroupSharedGroceryItem]
    @Query(sort: \GroupStoreAisle.sortIndex) private var allAisles: [GroupStoreAisle]
    @Query(sort: \GroupGroceryHistoryEntry.name) private var historicalItems: [GroupGroceryHistoryEntry]

    @State private var group: GroupDetail?
    @State private var lastSyncOutcome: GroupSyncService.SyncOutcome?
    @State private var showAddSheet = false
    @State private var showAislesManager = false
    @State private var showStaplesManager = false
    @State private var editingItem: GroupSharedGroceryItem?
    @State private var actionErrorMessage: String?

    @State private var viewMode: GroupGroceryViewMode = .byCategory
    /// Same "always active, real writable binding rather than `.constant`"
    /// reasoning as the personal `GroceryListView.editMode` — see that
    /// property's own doc comment.
    @State private var editMode: EditMode = .active
    // The only two collapsible sections on this screen, defaulted open —
    // same as the personal `GroceryListView`'s own `suggestionsExpanded`/
    // `pastGroceriesExpanded`.
    @State private var suggestionsExpanded = true
    @State private var pastGroceriesExpanded = true

    init(groupID: String, groupName: String) {
        self.groupID = groupID
        self.groupName = groupName
        // Same captured-local-constant `#Predicate` caution as
        // `GroupSharedMealPlanView.init` — see its own comment.
        let gid = groupID
        _items = Query(filter: #Predicate<GroupSharedGroceryItem> { $0.groupID == gid })
        _allAisles = Query(filter: #Predicate<GroupStoreAisle> { $0.groupID == gid }, sort: \GroupStoreAisle.sortIndex)
        _historicalItems = Query(filter: #Predicate<GroupGroceryHistoryEntry> { $0.groupID == gid }, sort: \GroupGroceryHistoryEntry.name)
    }

    private var myRole: GroupRole? { group?.myRole(currentUserID: accountSession.currentUser?.id) }
    private var isManager: Bool { myRole == .manager }

    private var hasPendingChanges: Bool {
        items.contains { $0.syncState != .synced } || allAisles.contains { $0.syncState != .synced }
    }

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
    private var visibleAisles: [GroupStoreAisle] {
        allAisles.filter { $0.syncState != .pendingDelete }
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
            Section {
            } header: {
                groceryListTitleHeader
            }

            if hasPendingChanges || isKnownOffline {
                Section {
                    Label(statusMessage, systemImage: "wifi.slash")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("View", selection: $viewMode) {
                    ForEach(GroupGroceryViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            if viewMode == .byCategory {
                byCategorySections
            } else {
                myLayoutSections
            }

            suggestionsSection

            pastGroceriesSection
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentAfterMenuDismiss { showStaplesManager = true }
                    } label: {
                        Label("Manage Staples", systemImage: "list.bullet.clipboard")
                    }
                    Button {
                        presentAfterMenuDismiss { showAislesManager = true }
                    } label: {
                        Label("Manage My Layout", systemImage: "square.grid.2x2")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
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
        .sheet(isPresented: $showAislesManager) {
            GroupAislesManagerView(groupID: groupID)
        }
        .sheet(isPresented: $showStaplesManager) {
            GroupStaplesManagerView(groupID: groupID)
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

    // MARK: - By category view

    @ViewBuilder
    private var byCategorySections: some View {
        if !purchasableByCategory.isEmpty {
            ForEach(Array(purchasableByCategory.enumerated()), id: \.element.0) { index, entry in
                let (category, categoryItems) = entry
                Section {
                    ForEach(categoryItems) { item in
                        row(for: item, moveMenu: moveToAisleMenu(for: item))
                            .contextMenu { moveToAisleMenu(for: item) }
                    }
                    .onMove { source, destination in
                        moveWithinCategory(categoryItems, from: source, to: destination)
                    }
                } header: {
                    Text(category.displayName)
                } footer: {
                    if index == purchasableByCategory.count - 1 {
                        Text("Drag the ≡ handle to reorder. Tap the ⋯ on an item (or touch and hold it) to move it to a different aisle in My Layout — any member can do this. Manage the group's standing staples and aisles from the toolbar.")
                    }
                }
            }
        } else {
            Section {
                Text("Nothing on your list yet. Tap + to add an item, or generate suggestions with one below.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reassigns `orderIndex` for every item in one category after a
    /// same-category reorder — same simple, whole-category-at-once approach
    /// as `GroceryListView.moveWithinCategory`. Any member may reorder — see
    /// this type's own doc comment.
    private func moveWithinCategory(_ categoryItems: [GroupSharedGroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = categoryItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
            markDirtyIfSynced(item)
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    // MARK: - "My Layout" view

    /// Where an item actually lands in "My Layout": an explicit choice
    /// (`item.aisleManuallySet == true`, including one that explicitly
    /// points at "Unsorted" — `aisleID == nil` with the flag still `true`)
    /// always wins; absent that, it falls back to whichever
    /// `GroupStoreAisle` mirrors the item's own `GroceryCategory` — the ten
    /// starter aisles the backend seeds once per group (see
    /// `AccountsAPIClient.getGroupGroceryAisles`'s own doc comment) — so "My
    /// Layout" defaults to the same grouping "By Category" uses instead of
    /// everything piling up in "Unsorted." Same reasoning as the personal
    /// `GroceryListView.resolvedAisleID`, adapted for this model's
    /// `aisleID`/`aisleManuallySet` living directly on the item (no separate
    /// join table the way the personal `ItemAisleAssignment` is one) — see
    /// `GroupSharedGroceryItem.aisleID`'s own doc comment for why.
    private func resolvedAisleID(for item: GroupSharedGroceryItem) -> String? {
        if item.aisleManuallySet { return item.aisleID }
        return visibleAisles.first { $0.linkedCategory == item.category }?.id
    }

    @ViewBuilder
    private var myLayoutSections: some View {
        let unassigned = purchasableItems.filter { resolvedAisleID(for: $0) == nil }.sorted(by: orderIndexIsBefore)

        if !unassigned.isEmpty {
            Section {
                ForEach(unassigned) { item in
                    row(for: item, moveMenu: moveToAisleMenu(for: item))
                        .contextMenu { moveToAisleMenu(for: item) }
                }
                .onMove { source, destination in
                    moveWithinLayoutGroup(unassigned, from: source, to: destination)
                }
            } header: {
                Text("Unsorted")
            } footer: {
                Text("Tap the ⋯ on an item (or touch and hold it) to place it into an aisle below.")
            }
        }

        ForEach(visibleAisles) { aisle in
            let aisleItems = purchasableItems.filter { resolvedAisleID(for: $0) == aisle.id }.sorted(by: orderIndexIsBefore)
            Section {
                if aisleItems.isEmpty {
                    Text("Nothing here yet.").font(.brandCaption).foregroundStyle(.tertiary)
                }
                ForEach(aisleItems) { item in
                    row(for: item, moveMenu: moveToAisleMenu(for: item))
                        .contextMenu { moveToAisleMenu(for: item) }
                }
                .onMove { source, destination in
                    moveWithinLayoutGroup(aisleItems, from: source, to: destination)
                }
            } header: {
                Text(aisle.name)
            }
        }
    }

    /// Reorders within one aisle/Unsorted group by rewriting `orderIndex` —
    /// the same field "By Category" sorts by (this model, unlike the
    /// personal `GroceryItem`, has no separate `layoutOrderIndex` — see
    /// `GroupGroceryItem` in prisma/schema.prisma, which only ever had one
    /// `orderIndex` column even after Phase 4 added aisle support). A
    /// judgment call worth flagging: reordering here also changes this
    /// item's position in "By Category," and vice versa — the two views
    /// share one physical sort key group-side, unlike the personal app's two
    /// independent ones. Acceptable for v1 (both orderings still work, they
    /// just aren't independent per view), and a real fix would need a
    /// backend schema change (a second `layoutOrderIndex` column), out of
    /// scope for this iOS-only task — see this feature's own final report.
    private func moveWithinLayoutGroup(_ groupItems: [GroupSharedGroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = groupItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
            markDirtyIfSynced(item)
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    /// Assigns `item` to `aisleID` (or explicitly to "Unsorted" —
    /// `aisleID == nil`), marking the placement as manually set either way —
    /// see `GroupSharedGroceryItem.aisleID`'s own doc comment on why an
    /// explicit `nil` still has to be persisted as a real choice, not left
    /// indistinguishable from "never touched." Any member may do this — see
    /// this type's own doc comment.
    private func moveToAisle(_ item: GroupSharedGroceryItem, aisleID: String?) {
        item.aisleID = aisleID
        item.aisleManuallySet = true
        markDirtyIfSynced(item)
        try? modelContext.save()
        Task { await runSync() }
    }

    @ViewBuilder
    private func moveToAisleMenu(for item: GroupSharedGroceryItem) -> some View {
        Menu {
            Button {
                moveToAisle(item, aisleID: nil)
            } label: {
                if resolvedAisleID(for: item) == nil {
                    Label("Unsorted", systemImage: "checkmark")
                } else {
                    Text("Unsorted")
                }
            }
            ForEach(visibleAisles) { aisle in
                Button {
                    moveToAisle(item, aisleID: aisle.id)
                } label: {
                    if resolvedAisleID(for: item) == aisle.id {
                        Label(aisle.name, systemImage: "checkmark")
                    } else {
                        Text(aisle.name)
                    }
                }
            }
        } label: {
            Label("Move to Aisle", systemImage: "square.grid.2x2")
        }
    }

    // MARK: - Suggested (participant-proposed, pending manager Accept/Reject)

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $suggestionsExpanded) {
                if !suggestedItems.isEmpty {
                    Button("Accept All") { acceptAllSuggested() }
                        .font(.brandCallout.bold())
                        .foregroundStyle(Color.brandForest)
                        .disabled(!isManager || isKnownOffline)
                    ForEach(suggestedItems) { item in
                        GroupGrocerySuggestionRow(
                            name: item.name,
                            quantityText: item.quantityText,
                            isSecondary: false,
                            addIsDisabled: !isManager || isKnownOffline || item.isLocalPlaceholderID,
                            onAdd: { Task { await accept(item) } },
                            onReject: (isManager || item.addedByUserID == accountSession.currentUser?.id)
                                ? { reject(item) } : nil
                        )
                    }
                } else {
                    Text("Nothing suggested right now.")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            } label: {
                majorHeader("Suggested")
            }
        } footer: {
            Text(isManager
                ? "Anyone can suggest an item for you to review — accept to move it onto the real list, or reject to remove it."
                : "Suggest an item here for a manager to review. You can still remove your own suggestion.")
        }
    }

    private func acceptAllSuggested() {
        guard isManager else { return }
        for item in suggestedItems where !item.isLocalPlaceholderID {
            Task { await accept(item) }
        }
    }

    private func accept(_ item: GroupSharedGroceryItem) async {
        do {
            try await GroupSyncService.acceptGroceryItem(groupID: groupID, itemID: item.id, modelContext: modelContext)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// "Reject" just removes the suggestion outright — same corrected
    /// semantics as the personal `GroceryListView.reject` and this backend's
    /// own `GroupGrocerySection` (which has no `REJECTED` case at all — see
    /// that enum's doc comment in prisma/schema.prisma).
    private func reject(_ item: GroupSharedGroceryItem) {
        delete(item)
    }

    // MARK: - Quick add from past groceries

    /// Always shown, even empty — same "don't make it disappear until
    /// something populates it" reasoning as the personal
    /// `GroceryListView.pastGroceriesSection`. No "Paste an Old List" entry
    /// point here (see this file's own top doc comment) — this fills in
    /// only automatically, as items get checked off.
    @ViewBuilder
    private var pastGroceriesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $pastGroceriesExpanded) {
                if historicalItems.isEmpty {
                    Text("Nothing here yet — this fills in automatically as your group checks items off below.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    Button("Add All", action: addAllHistorical)
                        .font(.brandCallout.bold())
                        .foregroundStyle(Color.brandForest)
                    ForEach(historicalItems) { historyItem in
                        GroupGrocerySuggestionRow(
                            name: historyItem.name,
                            quantityText: nil,
                            isSecondary: alreadyInList(historyItem),
                            addIsDisabled: alreadyInList(historyItem),
                            onAdd: { quickAdd(historyItem) },
                            onReject: nil
                        )
                    }
                }
            } label: {
                majorHeader("From Your Group's Past Groceries")
            }
        } footer: {
            Text("This fills in automatically as your group checks items off below — tap + (or Add All) to bring an item from here straight onto the list.")
        }
    }

    private func alreadyInList(_ historyItem: GroupGroceryHistoryEntry) -> Bool {
        let key = GroceryListBuilder.canonicalKey(for: historyItem.name)
        return items.contains { GroceryListBuilder.canonicalKey(for: $0.name) == key }
    }

    /// Any member may quick-add — same "routine list use" bucket as
    /// checking an item off; lands directly as `.thisWeek` (skipping the
    /// suggest-then-accept step) matching the personal app's own
    /// `quickAdd`. This does mean a `PARTICIPANT` can put something
    /// straight onto the real list via this one specific path — a
    /// deliberate parity choice with the personal reference rather than a
    /// role-gating gap: see this feature's own final report for the
    /// reasoning (the backend's `POST /groups/:groupId/grocery` itself would
    /// still reject a `PARTICIPANT`'s attempt to create with anything but
    /// `SUGGESTED`, so the eventual push of this row is done as a `.suggested`
    /// item for a `PARTICIPANT`, not `.thisWeek`, to avoid a push that can
    /// only ever fail).
    private func quickAdd(_ historyItem: GroupGroceryHistoryEntry) {
        guard !alreadyInList(historyItem), let currentUserID = accountSession.currentUser?.id else { return }
        let item = GroupSharedGroceryItem(
            id: GroupSharedGroceryItem.newLocalPlaceholderID(), groupID: groupID, name: historyItem.name,
            category: historyItem.category, section: isManager ? .thisWeek : .suggested,
            addedByUserID: currentUserID, syncState: .pendingCreate
        )
        modelContext.insert(item)
        try? modelContext.save()
        Task { await runSync() }
    }

    private func addAllHistorical() {
        for historyItem in historicalItems where !alreadyInList(historyItem) {
            quickAdd(historyItem)
        }
    }

    // MARK: - Rows

    /// `moveMenu` is rendered as an always-visible ⋯ button on the row
    /// itself, not just the `.contextMenu` long-press each call site also
    /// attaches — same "a permanently-active `EditMode` list doesn't
    /// reliably surface a row's long-press context menu on top of it"
    /// reasoning as the personal `GroceryListView.row(for:moveMenu:)`.
    private func row(for item: GroupSharedGroceryItem, moveMenu: some View) -> some View {
        GroupGroceryItemRow(
            item: item,
            isManager: isManager,
            onSetChecked: { checked in setChecked(item, checked) },
            onEdit: { editingItem = item },
            onDelete: { delete(item) },
            moveMenu: AnyView(moveMenu)
        )
    }

    /// Pronounced top-level heading, same as the personal
    /// `GroceryListView.majorHeader` — `.textCase(nil)` stops `List`'s
    /// default small-caps-gray section-header styling from overriding this.
    private func majorHeader(_ title: String) -> some View {
        Text(title)
            .font(.brandTitle3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, 4)
    }

    private var groceryListTitleHeader: some View {
        Text("Grocery List")
            .font(.brandLargeTitle)
            .foregroundStyle(Color.brandForest)
            .frame(maxWidth: .infinity, alignment: .center)
            .textCase(nil)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func loadGroup() async {
        group = try? await AccountsAPIClient.getGroup(id: groupID)
    }

    private func runSync() async {
        lastSyncOutcome = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext)
    }

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

    /// Marks a row as needing a push only if it was previously fully
    /// `.synced` — same reasoning as the original group screen's own
    /// `markDirtyIfSynced`; see `GroupSyncState`'s doc comment for the state
    /// machine this keeps consistent with.
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
}

// MARK: - Rows

/// One row shared by "Suggested" and "From Your Group's Past Groceries" —
/// the same layout and iconography in both places by design, matching the
/// personal `GrocerySuggestionRow` exactly (feedback there was that the two
/// lists should look alike; the same reasoning applies here).
private struct GroupGrocerySuggestionRow: View {
    let name: String
    let quantityText: String?
    let isSecondary: Bool
    let addIsDisabled: Bool
    let onAdd: () -> Void
    let onReject: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.titleCasedForDisplay)
                    .foregroundStyle(isSecondary ? .secondary : .primary)
                if let quantityText, !quantityText.isEmpty {
                    Text(quantityText)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let onReject {
                Button(action: onReject) {
                    Label("Reject", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
            }
            Button(action: onAdd) {
                Image(systemName: addIsDisabled ? "checkmark.circle.fill" : "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brandForest)
            .disabled(addIsDisabled)
        }
    }
}

private struct GroupGroceryItemRow: View {
    @Bindable var item: GroupSharedGroceryItem
    let isManager: Bool
    let onSetChecked: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// The "Move to Aisle" menu — see `GroupSharedGroceryListView.row(for:moveMenu:)`'s
    /// own doc comment for why this is shown as its own always-tappable
    /// button rather than relying solely on `.contextMenu`.
    let moveMenu: AnyView

    var body: some View {
        HStack {
            // Checking an item off is open to any member — mirrors
            // `PATCH .../grocery/:id`'s `isChecked` field, which has no role
            // gate at all.
            Button { onSetChecked(!item.isChecked) } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isChecked ? Color.brandForest : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.titleCasedForDisplay)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            if item.syncState != .synced {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.brandCaption2)
                    .foregroundStyle(.secondary)
                    .help("Not synced yet")
            }

            // Moving to a different aisle is open to any member — see
            // `GroupSharedGroceryListView`'s own doc comment.
            moveMenu
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)

            // Renaming/recategorizing/changing quantity or section is
            // MANAGER only — mirrors `PATCH .../grocery/:id`'s manager-only
            // fields exactly.
            if isManager {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            if !item.isChecked {
                Button {
                    onSetChecked(true)
                } label: {
                    Label("I Have It", systemImage: "checkmark")
                }
                .tint(.brandForest)
            }
        }
        .swipeActions(edge: .trailing) {
            // THIS_WEEK/STAPLES: any member may delete — routine
            // maintenance, mirrors `DELETE .../grocery/:id` on a
            // non-suggested item exactly.
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
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
/// dismisses immediately, same offline-first pattern as the meal plan's own
/// `GroupMealSheetContent`. A fresh item always starts with no aisle
/// explicitly chosen (`aisleManuallySet: false`, the model's own default),
/// so it immediately falls back to its category's default aisle in "My
/// Layout" rather than starting in "Unsorted."
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
/// own doc comment for why. Never touches `aisleID`/`aisleManuallySet` —
/// that stays the "Move to Aisle" menu's job (any member, a different action
/// entirely — see `GroupSharedGroceryListView.moveToAisle`).
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

        // Still `.pendingCreate` (no real server id yet) -> there is no
        // server row for a `PATCH` to target; apply the edit locally instead
        // and leave `syncState` as `.pendingCreate` — same reasoning as the
        // original group screen's own identical branch.
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
