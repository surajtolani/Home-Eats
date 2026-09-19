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
/// **One list, one "Prepopulate Groceries" entry point** (named "Add
/// Groceries" until a later direct request to rename it) — a redesign per direct
/// user feedback (with a reference screenshot of another app's flow
/// attached): the previous version of this screen kept three things open
/// on screen at once — the actual list, an always-expanded "Suggested From
/// Your Cooking List" section with its own day-strip/Generate control and
/// review queue inline, and an always-expanded "From Your Household
/// Groceries" section — which the user summed up as "not that good right
/// now and very confusing." Every one of those capabilities is still here,
/// just consolidated: `addGroceriesButton` below opens `AddGroceriesSheet`
/// (`GroupAddGroceriesFlow.swift`), a single sheet offering three focused
/// flows — type/search a plain item, generate ingredients from planned
/// meals (with a genuine review-and-check-off step before anything's
/// created), or quick-add from your own personal "My Usuals" catalog (the
/// same `HistoricalGroceryItem` table the old "Household Groceries"
/// section read, tabbed by category here). Pending `.suggested` items (a
/// PARTICIPANT's own suggestion, or a MANAGER's reviewed cooking-list pick)
/// still collect in one review queue for a MANAGER to accept/reject — this
/// used to be reachable only via a tap-through banner/sheet
/// (`SuggestedItemsReviewView`), but direct user feedback after that
/// shipped ("what does 'X items suggested' mean, where's it populating
/// from?") led to putting the queue back inline, right in the list itself
/// — see `suggestedItemsSection`'s own doc comment. The always-visible
/// name-only `quickAddField` at the very top of the list is also unchanged
/// — see that property's own doc comment for the role-gating and "why keep
/// the detailed sheet too" reasoning.
///
/// **By Category / My Layout, each organized differently.** The two modes
/// genuinely differ in what they're for, not just in visuals — and both
/// underwent a second, corrective redesign after direct user reports that
/// the first pass didn't actually work right (see each bullet below):
/// - **By Category** (`byCategorySections`) groups by `GroceryCategory` —
///   only categories with something on the list, in the enum's fixed
///   order; an empty category simply doesn't appear (direct user request:
///   "if there isn't an item in a category, I wouldn't show the
///   category... only pop up if there is something in it or if something
///   gets added" — see `purchasableByCategory`'s own doc comment). This
///   used to also let category *sections themselves* drag-to-reorder —
///   removed outright after a direct bug report that the reorder handle
///   "glitches and reverts": a plain SwiftUI `List`'s `.onMove` reordering
///   `Section`s produced by a `ForEach` that's itself wrapped in this
///   screen's `viewMode` conditional is a known-unreliable combination, not
///   something worth continuing to fight. Items inside a category are
///   always alphabetical (no manual per-item reordering there either).
///   What IS real: an item can move to a *different* category two ways —
///   drag it (`.draggable(item.id)`) onto a category header
///   (`GroceryDropHeader`, a real drop target with visual highlight while
///   targeted) if that category is already showing, or tap its own row's
///   "Move to Category" ⋯ menu (`moveToCategoryMenu`, which always lists
///   every category regardless of what's currently shown) either way —
///   the only path into a category with nothing in it yet.
/// - **My Layout** (`myLayoutSections`) groups by the group's own
///   `GroupStoreAisle` rows instead — custom sections anyone can add/
///   rename/reorder via "Manage My Layout" (`GroupAislesManagerView`,
///   reachable from the toggle row's own menu, which now keeps its reorder
///   handles permanently visible instead of hidden behind an "Edit" tap —
///   direct user report that there was "no way to know it's movable"
///   without already knowing to look for one). A brand-new group starts
///   with zero aisle sections at all (just "Unsorted") — direct user
///   request ("there should be no categories... think of how a notepad
///   works") — see the backend `GroupStoreAisle` model's own doc comment
///   in prisma/schema.prisma for the removed default-seeding behavior that
///   used to pre-populate ten category-named ones (a group seeded before
///   that removal keeps its existing aisles until manually deleted via
///   "Manage My Layout," which now has a one-tap "Remove Starter Aisles"
///   action for exactly that cleanup). Items are draggable within a
///   section via the List reorder handle (`moveWithinLayoutGroup` — a
///   single `ForEach`/`Section`, not the cross-section case above, so this
///   one IS reliable) and moveable *between* sections the same two ways as
///   By Category: drag onto a section's `GroceryDropHeader`, or the
///   row's own "Move to Aisle" ⋯ menu (`moveToAisleMenu`, `moveToAisle`).
///   Unlike By Category's fixed order, this layout is genuinely
///   group-shared (synced via `GroupSyncService`).
///
/// **No "Staples" here.** A standing group "staples" template list
/// (`GroupStaplesManagerView`, reachable from this screen's toolbar) used to
/// exist alongside "By Category"/"My Layout" — removed outright per direct
/// user feedback that the concept added nothing useful. This is unrelated
/// to `GroupGrocerySection.staples`, still very much present below
/// (`purchasableItems`'s filter): that's a tag on one specific line already
/// on the live list (mirroring the personal `GroceryListSection.staples`),
/// not a standing template — see `GroupStoreAisle`'s doc comment in
/// HomeEats/Models/GroupGroceryLayout.swift for the fuller removal note.
///
/// **Local-first / sync**: same design as `GroupSharedMealPlanView` — see
/// that view's and `GroupSyncService`'s own doc comments for the full
/// push/pull/reconcile story, the periodic-resync loop, and the offline
/// indicator's reasoning; not repeated here.
///
/// **Role gating**: mirrors routes/groupGrocery.js's field-by-field split
/// exactly — any member can check an item off, adjust its quantity, reorder
/// it within "My Layout," or move it to a different aisle there (all of
/// `isChecked`/`orderIndex`/`aisleId`, the "routine, day-to-day use" bucket
/// that field-by-field split draws on — see routes/groupGrocery.js's own
/// doc comment on its PATCH route); only a `MANAGER` can add an item
/// straight onto the real list, edit its name/category/quantity/section
/// (`MANAGER_ONLY_FIELDS` server-side — which is also why moving an item to
/// a different *category* in "By Category," drag or menu, is `MANAGER`-only
/// too, unlike moving it to a different *aisle* in "My Layout" — see
/// `moveToCategory`'s own doc comment), or accept a suggestion; a
/// `PARTICIPANT` can only suggest (create with `section: .suggested`) and
/// can remove their own suggestion (or any `THIS_WEEK`/`STAPLES` item —
/// routine maintenance, open to anyone). Managing "My Layout" aisles is
/// open to any member too — see `GroupAislesManagerView`'s own doc comment.
/// The quick-add field at the top of the list, and every path through
/// `AddGroceriesSheet`, follow this exact same MANAGER-decides/
/// PARTICIPANT-suggests split — see `quickAddField`'s and
/// `GroupAddGroceriesFlow.swift`'s own doc comments.
struct GroupSharedGroceryListView: View {
    let groupID: String
    let groupName: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @Query private var items: [GroupSharedGroceryItem]
    @Query(sort: \GroupStoreAisle.sortIndex) private var allAisles: [GroupStoreAisle]

    @State private var group: GroupDetail?
    @State private var lastSyncOutcome: GroupSyncService.SyncOutcome?
    @State private var showAddGroceriesSheet = false
    @State private var showAislesManager = false
    @State private var editingItem: GroupSharedGroceryItem?
    @State private var actionErrorMessage: String?

    /// Backs `quickAddField` — see that property's own doc comment.
    @State private var quickAddText = ""
    @State private var viewMode: GroupGroceryViewMode = .byCategory
    /// Same "always active, real writable binding rather than `.constant`"
    /// reasoning as the personal `GroceryListView.editMode` — see that
    /// property's own doc comment.
    @State private var editMode: EditMode = .active
    /// Backs `quickAddField`'s `TextField` — same "no way to dismiss the
    /// keyboard" fix as `RestaurantListView.isSearchFieldFocused`, applied
    /// here too since this field copies that same search-bar-styled
    /// `TextField` pattern.
    @FocusState private var isQuickAddFocused: Bool

    init(groupID: String, groupName: String) {
        self.groupID = groupID
        self.groupName = groupName
        // Same captured-local-constant `#Predicate` caution as
        // `GroupSharedMealPlanView.init` — see its own comment.
        let gid = groupID
        _items = Query(filter: #Predicate<GroupSharedGroceryItem> { $0.groupID == gid })
        _allAisles = Query(filter: #Predicate<GroupStoreAisle> { $0.groupID == gid }, sort: \GroupStoreAisle.sortIndex)
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

    /// Aisles a "Move to Aisle" action can actually target — `visibleAisles`
    /// minus any still-`.pendingCreate` one. A fresh aisle's `id` is still a
    /// local placeholder (`GroupStoreAisle.newLocalPlaceholderID()`), not the
    /// real, stable id `PATCH .../grocery/:id`'s `aisleId` field requires
    /// (validated server-side as `z.string().uuid()` — see
    /// routes/groupGrocery.js); `GroupSyncService.push` runs
    /// `pushGroceryItems` *before* `pushAisles` in the same cycle (see that
    /// method's own ordering), so an item assigned to a brand-new aisle in
    /// the same offline stretch it was created in would have its aisle
    /// placement PATCHed with that placeholder string in the very same sync
    /// the aisle itself is about to be swapped onto its real server id —
    /// and, unlike a genuine relationship, `GroupSharedGroceryItem.aisleID`
    /// is a plain `String`, not something `GroupSyncService.applyRemote(_:to:
    /// GroupStoreAisle)` updates every referencing item to match when the
    /// aisle's own id changes. Left unguarded, that PATCH — and every retry
    /// after it — would fail forever, permanently stranding the item's aisle
    /// placement. Excluding a not-yet-synced aisle from this menu closes the
    /// gap outright rather than trying to reconcile a stale reference after
    /// the fact; a fresh aisle drops back in and becomes assignable as soon
    /// as its own create actually lands (near-instant in practice, since
    /// `GroupAislesManagerView.addAisle` triggers a sync right after
    /// inserting it).
    private var assignableAisles: [GroupStoreAisle] {
        visibleAisles.filter { !$0.isLocalPlaceholderID }
    }

    private var suggestedItems: [GroupSharedGroceryItem] {
        visibleItems.filter { $0.section == .suggested }.sorted { $0.name < $1.name }
    }

    private var purchasableItems: [GroupSharedGroceryItem] {
        visibleItems.filter { $0.section == .thisWeek || $0.section == .staples }
    }

    /// Every `GroceryCategory` that currently has at least one item on it,
    /// in the enum's own fixed `sortIndex` order — direct user request:
    /// "if there isn't an item in a category, I wouldn't show the
    /// category. Categories should only pop up if there is something in it
    /// or if something gets added." This used to always show all ten
    /// categories, even empty ones — originally so `byCategorySections`'
    /// drag-and-drop had a header to drop onto for a category with nothing
    /// in it yet, but the "Move to Category" ⋯ menu (`moveToCategoryMenu`,
    /// listing every `GroceryCategory` regardless of what's currently
    /// shown) already covers that exact case without needing an empty
    /// section on screen — dragging just stops being how you move
    /// something into a category with nothing in it yet, the menu is.
    /// Items inside each category are always alphabetical — no per-item
    /// manual ordering.
    private var purchasableByCategory: [(GroceryCategory, [GroupSharedGroceryItem])] {
        let grouped = Dictionary(grouping: purchasableItems, by: \.category)
        return GroceryCategory.allCases.compactMap { category in
            guard let categoryItems = grouped[category], !categoryItems.isEmpty else { return nil }
            let sorted = categoryItems.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return (category, sorted)
        }
    }

    /// "My Layout" only (see `myLayoutSections`) — "By Category" sorts
    /// alphabetically instead (`purchasableByCategory` above). Same
    /// tie-breaking-by-id reasoning as `GroceryListView.orderIndexIsBefore`
    /// — every never-manually-reordered item defaults to `orderIndex == 0`,
    /// so falling back to `id` keeps ties from visibly swapping places
    /// across re-renders for no real reason.
    private func orderIndexIsBefore(_ lhs: GroupSharedGroceryItem, _ rhs: GroupSharedGroceryItem) -> Bool {
        lhs.orderIndex != rhs.orderIndex ? lhs.orderIndex < rhs.orderIndex : lhs.id < rhs.id
    }

    var body: some View {
        VStack(spacing: 0) {
            groceryListTitleHeader
                .padding(.horizontal)

            // The By Category/My Layout toggle AND "Manage My Layout"
            // together — reinstated after a brief removal (direct user
            // follow-up: "can we please re-add that back including the
            // icons to select by category and by layout"). Placed directly
            // under the title, ahead of the quick-add search bar below —
            // same positioning as before it was removed.
            HStack(spacing: 8) {
                Picker("View", selection: $viewMode) {
                    ForEach(GroupGroceryViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Menu {
                    Button {
                        presentAfterMenuDismiss { showAislesManager = true }
                    } label: {
                        Label("Manage My Layout", systemImage: "square.grid.2x2")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            quickAddField
                .padding(.horizontal)
                .padding(.vertical, 10)

            // Direct user request: a visible border/card around the actual
            // list of grocery items specifically, distinct from the title/
            // toggle/search chrome above it and the "Prepopulate Groceries"
            // CTA below — `.clipShape` rounds the `List`'s own row content
            // to match the `.overlay` stroke drawn on top of it (without
            // it, the List's square row corners would poke past the
            // rounded border at each corner).
            List {
                if viewMode == .byCategory {
                    byCategorySections
                } else {
                    myLayoutSections
                }

                // Direct user request: below the real grocery items, not
                // above them.
                suggestedItemsSection
            }
            // `.plain`, not the default inset-grouped style — direct user
            // report of "an unnecessary lot of extra space at the top below
            // 'grocery list'": the default List style reserves noticeably
            // more padding above a List's first section header than
            // `.plain` does, on top of wrapping every section in its own
            // inset card. Matches every other main-tab List-based screen in
            // this app (`RecipesHomeView`, `CalendarPlanView`,
            // `GroupSharedMealPlanView` all already use `.plain`).
            .listStyle(.plain)
            // Same "no way to dismiss the keyboard" fix as
            // `RestaurantListView`'s identical `List` modifier — see that
            // one's own doc comment.
            .scrollDismissesKeyboard(.immediately)
            // Needs to sit on the `List` itself, not the outer `VStack` —
            // pull-to-refresh only has something to attach its gesture to
            // where the actual scrollable content lives, now that the
            // title/toggle/search/banner chrome above it is a plain,
            // non-scrolling `VStack` row.
            .refreshable {
                // Also re-fetch the group itself, not just item sync — a
                // role change (promote/demote) only lands here, and without
                // this a pull-to-refresh wouldn't pick it up either.
                await loadGroup()
                await runSync()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .padding(.horizontal)

            addGroceriesButton
                .padding(.horizontal)
                .padding(.vertical, 12)
        }
        // `.syncStatusOverlay` (see `SyncStatusBanner.swift`) floats this at
        // the BOTTOM of the whole screen, as a true overlay rather than
        // occupying real layout space — this used to be a `Section` right
        // in the `List`, and a quantity bump, checkbox tap, or vote briefly
        // flipping `hasPendingChanges` on and off (usually well under a
        // second, until the immediate follow-up sync clears it) shifted
        // every row below it, the same "screen skips/jumps" bug
        // `GroupSharedMealPlanView` had — see that shared type's own doc
        // comment for the full reasoning, including why bottom rather than
        // top. Attached to the outer `VStack` (not just the bordered
        // `List` above) now that the screen has non-list chrome below the
        // list too (`addGroceriesButton`) — it should float over the whole
        // screen's bottom edge, not just the list card's.
        .syncStatusOverlay(isVisible: hasPendingChanges || isKnownOffline, message: statusMessage)
        .environment(\.editMode, $editMode)
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadGroup()
            await runSync()
            await runPeriodicSyncLoop()
        }
        .sheet(isPresented: $showAddGroceriesSheet) {
            AddGroceriesSheet(groupID: groupID, isManager: isManager, isKnownOffline: isKnownOffline)
        }
        .sheet(item: $editingItem) { item in
            EditGroupGroceryItemSheet(groupID: groupID, item: item) { errorMessage in
                actionErrorMessage = errorMessage
            }
        }
        .sheet(isPresented: $showAislesManager) {
            GroupAislesManagerView(groupID: groupID)
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

    // MARK: - Suggested queue (inline in the list) + Prepopulate Groceries entry point

    /// Both a PARTICIPANT's own typed suggestion and a MANAGER's reviewed
    /// `AddGroceriesSheet` pick (see `GroupAddGroceriesFlow.swift`'s
    /// `ReviewIngredientsView`) land in this exact same `.suggested` review
    /// queue. This used to be reachable only through a tap-through banner
    /// opening a separate review sheet — direct user feedback after that
    /// shipped was that it wasn't obvious what "N items suggested" even
    /// meant or where it came from, and asked for it back inline in the
    /// real list instead, each row showing who suggested it with add/
    /// remove actions right there. Titled "Items Suggested by Group
    /// Members" (was "Suggested Grocery Items") and placed BELOW the real
    /// `byCategorySections`/`myLayoutSections` content (was above) — both
    /// direct follow-up requests, so the real, already-decided list reads
    /// first and this pending-review queue reads as a distinct, secondary
    /// thing underneath it. `@ViewBuilder` (not a plain `if` at the
    /// `List`'s own call site) so the section itself — including its
    /// header/footer — simply doesn't render when there's nothing pending,
    /// rather than rendering an empty section shell.
    @ViewBuilder
    private var suggestedItemsSection: some View {
        if !suggestedItems.isEmpty {
            Section {
                ForEach(suggestedItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name.titleCasedForDisplay)
                            HStack(spacing: 4) {
                                if !item.quantityText.isEmpty {
                                    Text(item.quantityText)
                                }
                                Text("Suggested by \(memberName(item.addedByUserID))")
                            }
                            .font(.brandCaption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.syncState != .synced {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.brandCaption2)
                                .foregroundStyle(.secondary)
                                .help("Not synced yet")
                        }
                        // Reject: a MANAGER can remove any suggestion;
                        // anyone can remove their own — same role split the
                        // old review sheet enforced.
                        if isManager || item.addedByUserID == accountSession.currentUser?.id {
                            Button {
                                reject(item)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        // Accept: MANAGER-only, and only once this row has
                        // a real server id to accept (never a still-
                        // `.pendingCreate` placeholder — same guard the old
                        // review sheet used).
                        Button {
                            Task { await accept(item) }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandForest)
                        .disabled(!isManager || isKnownOffline || item.isLocalPlaceholderID)
                    }
                }
            } header: {
                Text("Items Suggested by Group Members")
            } footer: {
                Text(isManager
                    ? "Anyone can suggest an item for you to review — tap + to add it to the real list, or the x to remove it."
                    : "Suggest an item for a manager to review. You can still remove your own suggestion.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func memberName(_ userID: String) -> String {
        group?.members.first(where: { $0.id == userID })?.displayNameOrPhoneNumber ?? "Someone"
    }

    private func accept(_ item: GroupSharedGroceryItem) async {
        do {
            try await GroupSyncService.acceptGroceryItem(groupID: groupID, itemID: item.id, modelContext: modelContext)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// "Reject" just removes the suggestion outright — same corrected
    /// semantics as the personal `GroceryListView.reject` and this
    /// backend's own `GroupGrocerySection` (which has no `REJECTED` case
    /// at all — see that enum's doc comment in prisma/schema.prisma).
    /// Reuses `delete(_:)` below — identical local-placeholder-vs-real-row
    /// handling either way.
    private func reject(_ item: GroupSharedGroceryItem) {
        delete(item)
    }

    /// The single entry point for every way to add something onto this
    /// list beyond the plain-name `quickAddField` above — see
    /// `AddGroceriesSheet`'s own doc comment in GroupAddGroceriesFlow.swift
    /// for the full "why one button now, not three always-open sections"
    /// reasoning.
    private var addGroceriesButton: some View {
        Button {
            showAddGroceriesSheet = true
        } label: {
            Label("Prepopulate Groceries", systemImage: "plus.circle.fill")
                .font(.brandSubheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brandForest)
    }

    // MARK: - By category view

    /// Reassigns `item.category` — the actual move behind both the "Move to
    /// Category" menu and dragging an item onto a category header
    /// (`GroceryDropHeader`, below). **`MANAGER`-only** — unlike `aisleId`
    /// (My Layout placement, any member), `category` is one of
    /// routes/groupGrocery.js's `MANAGER_ONLY_FIELDS` (alongside `name`/
    /// `quantityText`/`section`): a PARTICIPANT's own attempt to change it
    /// would sync-reject silently, which is exactly the kind of "looks like
    /// it moved, then reverts" bug this screen already had a real one of
    /// (see `purchasableByCategory`'s own doc comment) — so the UI never
    /// offers this at all to a non-`MANAGER` (see `byCategorySections`'
    /// `isManager` branch), and this guards defensively too in case a role
    /// change hasn't refreshed locally yet.
    private func moveToCategory(_ item: GroupSharedGroceryItem, category: GroceryCategory) {
        guard isManager else { return }
        item.category = category
        markDirtyIfSynced(item)
        try? modelContext.save()
        Task { await runSync() }
    }

    /// Resolves a dragged item's id (see `GroceryDropHeader`/`row(for:)`'s
    /// own `.draggable(item.id)`) back to the actual `GroupSharedGroceryItem`
    /// and moves it — `visibleItems`, not just `purchasableItems`, so a drop
    /// still resolves correctly in the rare case an item's section changed
    /// out from under it between the drag starting and the drop landing.
    private func handleCategoryDrop(itemID: String, category: GroceryCategory) {
        guard let item = visibleItems.first(where: { $0.id == itemID }) else { return }
        moveToCategory(item, category: category)
    }

    @ViewBuilder
    private func moveToCategoryMenu(for item: GroupSharedGroceryItem) -> some View {
        Menu {
            ForEach(GroceryCategory.allCases) { category in
                Button {
                    moveToCategory(item, category: category)
                } label: {
                    if item.category == category {
                        Label(category.displayName, systemImage: "checkmark")
                    } else {
                        Text(category.displayName)
                    }
                }
            }
        } label: {
            Label("Move to Category", systemImage: "arrow.left.arrow.right")
        }
    }

    /// Direct user feedback, several rounds over: the previous design let
    /// category *sections themselves* drag-to-reorder, which didn't
    /// reliably work ("glitches and reverts" — a known real SwiftUI
    /// limitation, not something worth continuing to fight); this version
    /// drops section reordering entirely and instead makes moving an ITEM
    /// real: for a `MANAGER` (the only role allowed to touch `category` at
    /// all — see `moveToCategory`'s own doc comment), drag it (long-press,
    /// same gesture `.draggable` uses everywhere in iOS — Files, Mail, ...)
    /// onto a category's header to move it there, or use the "Move to
    /// Category" ⋯ menu/long-press context menu as a reliable,
    /// always-available alternative to dragging — including into a
    /// category with nothing in it yet, which (per `purchasableByCategory`'s
    /// own doc comment) has no header on screen to drag onto in the first
    /// place. A `PARTICIPANT` sees neither — just the plain row and a
    /// non-interactive header — since attempting either would only
    /// sync-reject.
    @ViewBuilder
    private var byCategorySections: some View {
        if purchasableItems.isEmpty {
            Section {
                Text("Nothing on your list yet. Type something above, or tap Prepopulate Groceries below.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(purchasableByCategory, id: \.0) { category, categoryItems in
            Section {
                ForEach(categoryItems) { item in
                    if isManager {
                        row(for: item, moveMenu: moveToCategoryMenu(for: item))
                            .contextMenu { moveToCategoryMenu(for: item) }
                            .draggable(item.id)
                    } else {
                        row(for: item, moveMenu: EmptyView())
                    }
                }
            } header: {
                GroceryDropHeader(
                    title: category.displayName,
                    tint: Color.brandSage,
                    isInteractive: isManager
                ) { itemID in
                    handleCategoryDrop(itemID: itemID, category: category)
                }
            } footer: {
                if isManager && category == purchasableByCategory.last?.0 {
                    Text("Items within a category sort alphabetically. Drag an item onto a category name to move it there, or tap the ⋯ on an item.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - "My Layout" view

    /// Where an item actually lands in "My Layout": an explicit choice
    /// (`item.aisleManuallySet == true`, including one that explicitly
    /// points at "Unsorted" — `aisleID == nil` with the flag still `true`)
    /// always wins; absent that, it falls back to whichever `GroupStoreAisle`
    /// mirrors the item's own `GroceryCategory` — only ever true for a group
    /// that still has some of the old default-seeded starter aisles (see
    /// `GroupStoreAisle`'s own doc comment in prisma/schema.prisma; a
    /// brand-new group has no aisles with a `linkedCategory` at all, so this
    /// simply never matches and everything starts in "Unsorted" instead, as
    /// intended). Same reasoning as the personal `GroceryListView
    /// .resolvedAisleID`, adapted for this model's `aisleID`/
    /// `aisleManuallySet` living directly on the item (no separate join
    /// table the way the personal `ItemAisleAssignment` is one) — see
    /// `GroupSharedGroceryItem.aisleID`'s own doc comment for why.
    private func resolvedAisleID(for item: GroupSharedGroceryItem) -> String? {
        if item.aisleManuallySet { return item.aisleID }
        return visibleAisles.first { $0.linkedCategory == item.category }?.id
    }

    /// Same role as `handleCategoryDrop` above, for "My Layout" — resolves a
    /// dragged item's id back to the real row and reassigns its aisle.
    private func handleAisleDrop(itemID: String, aisleID: String?) {
        guard let item = visibleItems.first(where: { $0.id == itemID }) else { return }
        moveToAisle(item, aisleID: aisleID)
    }

    @ViewBuilder
    private var myLayoutSections: some View {
        let unassigned = purchasableItems.filter { resolvedAisleID(for: $0) == nil }.sorted(by: orderIndexIsBefore)

        if !unassigned.isEmpty {
            Section {
                ForEach(unassigned) { item in
                    row(for: item, moveMenu: moveToAisleMenu(for: item))
                        .contextMenu { moveToAisleMenu(for: item) }
                        .draggable(item.id)
                }
                .onMove { source, destination in
                    moveWithinLayoutGroup(unassigned, from: source, to: destination)
                }
            } header: {
                GroceryDropHeader(title: "Unsorted", tint: .primary) { itemID in
                    handleAisleDrop(itemID: itemID, aisleID: nil)
                }
            } footer: {
                Text("Drag the ≡ handle to reorder within a section, or drag an item onto a section name below to move it there. Tap the ⋯ on an item for the same move without dragging. Add your own sections from the toggle row's ⋯ menu above.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
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
                        .draggable(item.id)
                }
                .onMove { source, destination in
                    moveWithinLayoutGroup(aisleItems, from: source, to: destination)
                }
            } header: {
                GroceryDropHeader(title: aisle.name, tint: .primary) { itemID in
                    handleAisleDrop(itemID: itemID, aisleID: aisle.id)
                }
            }
        }
    }

    /// Reorders within one aisle/Unsorted group by rewriting `orderIndex` —
    /// the same field "By Category" used to sort by before switching to
    /// alphabetical (this model, unlike the personal `GroceryItem`, has no
    /// separate `layoutOrderIndex` — see `GroupGroceryItem` in
    /// prisma/schema.prisma, which only ever had one `orderIndex` column
    /// even after Phase 4 added aisle support). Reordering here no longer
    /// affects "By Category" (that view sorts alphabetically now,
    /// independent of `orderIndex`), so this is purely a "My Layout" concern.
    ///
    /// Only touches rows whose `orderIndex` actually changed (`where`
    /// clause below) — same guard `GroupAislesManagerView.move` already
    /// uses for the identical whole-list-rewrite reorder. Without it, every
    /// item in the section gets marked `.pendingUpdate` and PATCHed on every
    /// drag, not just the ones that actually moved — needless churn that
    /// also widens the window for `sync`'s per-group single-flight
    /// coalescing (see that method's own doc comment) to have something to
    /// coalesce in the first place.
    private func moveWithinLayoutGroup(_ groupItems: [GroupSharedGroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = groupItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() where item.orderIndex != Double(index) {
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
            ForEach(assignableAisles) { aisle in
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

    // MARK: - Rows

    /// `moveMenu` — "Move to Category" in By Category, "Move to Aisle" in
    /// My Layout — is rendered as an always-visible ⋯ button on the row
    /// itself, not just the `.contextMenu` long-press each call site also
    /// attaches — same "a permanently-active `EditMode` list doesn't
    /// reliably surface a row's long-press context menu on top of it"
    /// reasoning as the personal `GroceryListView.row(for:moveMenu:)`.
    private func row(for item: GroupSharedGroceryItem, moveMenu: some View) -> some View {
        GroupGroceryItemRow(
            item: item,
            isManager: isManager,
            onSetChecked: { checked in setChecked(item, checked) },
            onSetQuantityCount: { count in setQuantityCount(item, count) },
            onEdit: { editingItem = item },
            onDelete: { delete(item) },
            moveMenu: AnyView(moveMenu)
        )
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

    // MARK: - Quick add

    /// An always-visible, search-bar-styled `TextField` at the top of the
    /// list — type a name and hit Return (or tap the arrow) to add it
    /// immediately, no sheet involved at all. This is a direct fix for user
    /// feedback that adding an item required opening a modal for what's
    /// usually just a bare name.
    ///
    /// Deliberately a plain `TextField`, not `.searchable`: `.searchable`'s
    /// established meaning elsewhere in this app (`RestaurantListView`,
    /// `GroupRecipePickerSheet`) is "filter/find something that already
    /// exists" — this field's job is the opposite,
    /// to CREATE a new row, so reusing that same affordance for a different
    /// action would read as misleading despite the "search bar" look the
    /// feature request asked for.
    ///
    /// **Same role-gating as the existing sheet-based flow, no exceptions**:
    /// a `MANAGER`'s submission lands directly on the real list
    /// (`section: .thisWeek`); a `PARTICIPANT`'s lands as a `.suggested`
    /// item requiring a `MANAGER` to adopt it via `suggestedItemsSection`
    /// below — the exact same split `AddGroupGroceryItemSheet
    /// .submit()` already enforces (see that type's own doc comment for
    /// why: the backend's `POST /groups/:groupId/grocery` itself rejects
    /// any other section from a `PARTICIPANT`), just reached by pressing
    /// Return instead of opening a sheet and tapping "Add".
    ///
    /// **Why `AddGroupGroceryItemSheet` still exists alongside this,
    /// instead of being replaced by it**: this field is deliberately
    /// name-only — no category picker, no quantity, no (for a `MANAGER`)
    /// section picker — so a plain "milk" typed and submitted still needs
    /// *some* way to set a quantity or override the category `GroceryCategory
    /// .guess(fromIngredientName:)` gets wrong, or (for a `MANAGER`) to add
    /// straight into `.suggested`/`.staples` instead of the default
    /// `.thisWeek`. The existing sheet (reachable via `addGroceriesButton`
    /// -> "Add an Item" -> "Add a Custom Item," see `GroupAddGroceriesFlow
    /// .swift`'s `AddItemSearchView`) covers exactly that "I want to set
    /// more than just the name" case; this field covers the much more
    /// common "just add milk" case the user asked for directly, without
    /// regressing the other one.
    private var quickAddField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(isManager ? "Add an item" : "Suggest an item", text: $quickAddText)
                .focused($isQuickAddFocused)
                .submitLabel(.done)
                .onSubmit { submitQuickAdd() }
            if !quickAddText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submitQuickAdd) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandForest)
            }
        }
        // Same boxed look as `RecipesHomeView`/`RestaurantListView`'s own
        // search fields — direct user request to make this consistent with
        // the other tabs' search boxes instead of a bare, background-less
        // row.
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Inserts a `.pendingCreate` row straight from `quickAddText` — same
    /// local-first-insert-and-sync-in-the-background pattern as every other
    /// write on this screen (see `AddGroupGroceryItemSheet.submit()` for the
    /// sheet-based twin of this exact insert). `GroceryCategory
    /// .guess(fromIngredientName:)` is the same best-effort category guess
    /// the personal `AddGroceryItemSheet`/`StaplesManagerView` use for a
    /// name-only add — good enough for routine use, and a `MANAGER` can
    /// still correct it afterward via `EditGroupGroceryItemSheet` if it
    /// guesses wrong.
    private func submitQuickAdd() {
        let trimmedName = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let currentUserID = accountSession.currentUser?.id else { return }
        let item = GroupSharedGroceryItem(
            id: GroupSharedGroceryItem.newLocalPlaceholderID(),
            groupID: groupID,
            name: trimmedName,
            category: GroceryCategory.guess(fromIngredientName: trimmedName),
            section: isManager ? .thisWeek : .suggested,
            addedByUserID: currentUserID,
            syncState: .pendingCreate
        )
        modelContext.insert(item)
        try? modelContext.save()
        quickAddText = ""
        Task { await runSync() }
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
            // `runSync()` only syncs grocery items — group membership and
            // roles live in `group` (fetched by `loadGroup()`), which
            // otherwise never refreshes after the initial `.task` load. A
            // promoted/demoted member would stay stuck at their old
            // permissions on their own device until they force-quit the app.
            await loadGroup()
            await runSync()
        }
    }

    private func setChecked(_ item: GroupSharedGroceryItem, _ checked: Bool) {
        item.isChecked = checked
        markDirtyIfSynced(item)
        try? modelContext.save()
        Task { await runSync() }
    }

    /// Any member may adjust this — same "routine, day-to-day use of an
    /// already-decided list" bucket as `setChecked` above (see
    /// routes/groupGrocery.js's own comment on PATCH /:id). Deliberately
    /// NOT a direct `$item.quantityCount` binding the way the personal
    /// `GroceryListView`'s `QuantityStepper` uses — that model has no sync
    /// state to keep consistent; this one does, so every change has to go
    /// through `markDirtyIfSynced` + a follow-up `runSync()` the same way
    /// `setChecked` does, not just autosave silently.
    private func setQuantityCount(_ item: GroupSharedGroceryItem, _ count: Int) {
        item.quantityCount = count
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

// MARK: - Section headers

/// A category/aisle section header that's also a drop target — drag an
/// item (`.draggable(item.id)` on each row in `byCategorySections`/
/// `myLayoutSections`) onto this and drop it to move that item here.
/// Highlights while something's being dragged over it (`isTargeted`) so
/// there's real visual feedback that dropping here will do something —
/// direct user request, after "the 3 lines... doesn't really work" and "no
/// way to know it's movable" reports, that these interactions need to be
/// obviously discoverable rather than a hidden gesture nobody would find on
/// their own. A `String` payload (an item's own `id`) needs no custom
/// `Transferable` wrapper — `String` already conforms.
private struct GroceryDropHeader: View {
    let title: String
    let tint: Color
    /// `false` for a By Category header when the caller isn't a `MANAGER`
    /// (see `byCategorySections`' own doc comment on why — `category` is
    /// `MANAGER`-only server-side) — renders the plain title with no drop
    /// target/highlight at all, rather than looking interactive and then
    /// silently failing to sync. Always `true` for My Layout, where
    /// `aisleId` is open to any member.
    var isInteractive: Bool = true
    let onDrop: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        let label = Text(title)
            .font(.brandHeadline)
            .foregroundStyle(tint)
            .textCase(nil)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

        if isInteractive {
            label
                .background(
                    isTargeted ? tint.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { droppedIDs, _ in
                    guard let itemID = droppedIDs.first else { return false }
                    onDrop(itemID)
                    return true
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
        } else {
            label
        }
    }
}

// MARK: - Rows

private struct GroupGroceryItemRow: View {
    @Bindable var item: GroupSharedGroceryItem
    let isManager: Bool
    let onSetChecked: (Bool) -> Void
    let onSetQuantityCount: (Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// The "Move to Category"/"Move to Aisle" menu, shown inline right next
    /// to the item name — see `GroupSharedGroceryListView.row(for:moveMenu:)`'s
    /// own doc comment.
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
                HStack(spacing: 6) {
                    Text(item.name.titleCasedForDisplay)
                        .strikethrough(item.isChecked)
                        .foregroundStyle(item.isChecked ? .secondary : .primary)
                    moveMenu
                        .labelStyle(.iconOnly)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
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

            // `[trash-or-minus] N [+]` — same control, same behavior, as the
            // personal `GroceryListView`'s own `QuantityStepper`: direct user
            // request to bring it back on this screen too ("there should be
            // a trash can (if item count is 1) or a '-' if more than one,
            // the[n] the item count, then a plus sign"). Any member may
            // adjust it — same bucket as `isChecked`/`orderIndex` (routine,
            // day-to-day use of an already-decided list), not a manager-only
            // field — see `GroupSharedGroceryListView.setQuantityCount`'s
            // own doc comment for why this goes through that function
            // rather than a direct `$item.quantityCount` binding.
            GroupQuantityStepper(
                count: Binding(get: { item.quantityCount }, set: onSetQuantityCount),
                onDeleteAtMinimum: onDelete
            )
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
            // non-suggested item exactly. Kept alongside the trailing
            // `GroupQuantityStepper` above, whose own trash-at-minimum state
            // does the same thing (not redundant — some people reach for the
            // swipe out of habit, others the stepper; both do the same
            // thing).
            // `role: .destructive` alone doesn't render red on a
            // `.swipeActions` button — see `PlannedMealRow`'s identical
            // fix in DayDetailView.swift for the full explanation.
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
            if isManager {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.brandHoney)
            }
        }
    }
}

/// A `[-] N [+]` control for `GroupSharedGroceryItem.quantityCount` — direct
/// port of the personal `GroceryListView`'s own private `QuantityStepper`
/// (same visuals, same at-minimum-becomes-trash behavior), duplicated here
/// rather than shared/exported since that type is `private` to its own file
/// and this one needs its `count` changes routed through
/// `GroupSharedGroceryListView.setQuantityCount` (sync-state bookkeeping)
/// instead of a bare SwiftData binding — see `GroupGroceryItemRow`'s own
/// call site for why.
private struct GroupQuantityStepper: View {
    @Binding var count: Int
    let onDeleteAtMinimum: () -> Void

    private var isAtMinimum: Bool { count <= 1 }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isAtMinimum {
                    onDeleteAtMinimum()
                } else {
                    count -= 1
                }
            } label: {
                Image(systemName: isAtMinimum ? "trash" : "minus.circle")
            }
            .foregroundStyle(isAtMinimum ? Color.brandTerracotta : Color.brandForest)

            Text("\(count)")
                .font(.brandCaption)
                .monospacedDigit()
                .frame(minWidth: 16)
                .foregroundStyle(Color.brandForest)

            Button {
                count += 1
            } label: {
                Image(systemName: "plus.circle")
            }
            .foregroundStyle(Color.brandForest)
        }
        .buttonStyle(.plain)
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
/// Layout" rather than starting in "Unsorted." Not `private` — reused by
/// `GroupAddGroceriesFlow.swift`'s `AddItemSearchView` ("Add a Custom
/// Item"), which needs more than this screen's own name-only quick add.
struct AddGroupGroceryItemSheet: View {
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
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
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
/// that stays "My Layout"'s "Move to Aisle" menu's own job (any member, a
/// different action entirely — see `GroupSharedGroceryListView.moveToAisle`).
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
