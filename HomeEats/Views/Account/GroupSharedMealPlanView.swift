import SwiftUI
import SwiftData

/// A single group's own meal plan — day-by-day decided meals and pending
/// suggestions, scoped to one `groupID` (never shared across groups; each
/// group has its own independent plan). This is what the main "Plan" tab
/// shows for whichever group is currently active (see `GroupScopedPlanTab`
/// in RootView.swift), and is also reachable directly from
/// `GroupDetailView`'s "Meal Plan" link for a non-active group.
/// A new screen, not a modification of the existing personal-use
/// `DaySlotsView`/`CalendarPlanView` (see this feature's own scope notes —
/// those stay untouched): this reuses their *visual* language (the
/// icon+pill decided-meal row, the vote-count/"Use This" suggestion row)
/// as fresh views built against the new `GroupPlannedMeal`/
/// `GroupMealSuggestion` SwiftData models, since the existing views are
/// tightly coupled to the local, personal `@Query` data they already read.
///
/// **Local-first**: every row shown here comes straight from the on-device
/// SwiftData store, so this screen reads and writes instantly whether
/// online or off. `GroupSyncService.sync` runs in the background — on
/// appearance, on pull-to-refresh, and on a light periodic timer for as
/// long as this screen stays on-screen (the `while` loop inside `.task`
/// below, cancelled automatically the moment SwiftUI tears this view down)
/// — to push whatever's pending and pull the group's latest state. See
/// `GroupSyncService`'s own doc comment for the full sync/reconcile design
/// and its "Known limitations" note.
///
/// **Role gating**: mirrors the backend's own MANAGER/PARTICIPANT split
/// exactly (see routes/groupMealPlan.js) — a `MANAGER` sees "Add to Plan"
/// (decides a meal directly) and "Use This" (adopts a suggestion); a
/// `PARTICIPANT` only ever sees "Suggest for a Vote" and the vote button
/// itself, same "never offer an action that would just 403" standard the
/// rest of this feature holds to (see `DaySlotsView`'s own decide-vs-suggest
/// button split, which this mirrors the *shape* of, gated here by role
/// instead of by nothing at all).
struct GroupSharedMealPlanView: View {
    let groupID: String
    let groupName: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @Query private var plannedMeals: [GroupPlannedMeal]
    @Query private var suggestions: [GroupMealSuggestion]

    @State private var group: GroupDetail?
    @State private var lastSyncOutcome: GroupSyncService.SyncOutcome?
    @State private var activeSheet: ActiveSheet?
    @State private var actionErrorMessage: String?

    init(groupID: String, groupName: String) {
        self.groupID = groupID
        self.groupName = groupName
        // Captured into a local constant before use inside `#Predicate`,
        // matching this codebase's own established caution around what
        // that macro can reliably close over (see
        // `SampleDataSeeder.seedSettingsIfNeeded`'s identical pattern) —
        // simple captured String equality like this is the well-supported
        // case that pattern demonstrates, unlike filtering on a custom enum
        // (`syncState`), which `GroupSyncService` deliberately does in plain
        // Swift instead (see its own comment on why).
        let gid = groupID
        _plannedMeals = Query(filter: #Predicate<GroupPlannedMeal> { $0.groupID == gid }, sort: \GroupPlannedMeal.date)
        _suggestions = Query(filter: #Predicate<GroupMealSuggestion> { $0.groupID == gid }, sort: \GroupMealSuggestion.date)
    }

    private var myRole: GroupRole? { group?.myRole(currentUserID: accountSession.currentUser?.id) }
    private var isManager: Bool { myRole == .manager }

    /// The `@Query` results with any `.pendingDelete` row filtered out —
    /// every view below reads through these, never `plannedMeals`/
    /// `suggestions` directly, so a swipe-to-delete/withdraw removes a row
    /// from view immediately (optimistic), rather than leaving it fully
    /// visible and interactive until the next successful push actually
    /// removes it from the store. The row itself still exists locally in
    /// the meantime (`GroupSyncService.push` is what actually deletes it,
    /// on success) — only its visibility here is optimistic.
    private var visiblePlannedMeals: [GroupPlannedMeal] {
        plannedMeals.filter { $0.syncState != .pendingDelete }
    }
    private var visibleSuggestions: [GroupMealSuggestion] {
        suggestions.filter { $0.syncState != .pendingDelete }
    }

    /// Any row not yet fully reconciled with the server — drives the
    /// "not synced yet" banner independent of `lastSyncOutcome`, which only
    /// reflects the *last completed* sync cycle and would otherwise still
    /// read as fully-synced for a moment right after a brand-new local edit.
    private var hasPendingChanges: Bool {
        plannedMeals.contains { $0.syncState != .synced } || suggestions.contains { $0.syncState != .synced }
    }

    /// Whether the last completed sync couldn't reach the server at all —
    /// used to disable the online-only manager actions (`Use This`) rather
    /// than let them fail with a confusing error every time. Not a live
    /// reachability check (this app has none elsewhere either); a stale
    /// read here just means the button attempts the call and shows an
    /// inline error on failure instead, which is still a fine fallback.
    private var isKnownOffline: Bool {
        guard let lastSyncOutcome else { return false }
        return !lastSyncOutcome.pullSucceeded
    }

    private var allDates: [Date] {
        Set(visiblePlannedMeals.map(\.date)).union(visibleSuggestions.map(\.date)).sorted()
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

            if visiblePlannedMeals.isEmpty && visibleSuggestions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing Planned Yet",
                        systemImage: "calendar",
                        description: Text(isManager
                            ? "Tap + to add the first meal to this group's plan."
                            : "Tap + to suggest the first meal — a manager can add it once there's agreement.")
                    )
                }
            } else {
                ForEach(allDates, id: \.self) { date in
                    daySection(date)
                }
            }
        }
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .addMeal
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadGroup()
            await runSync()
            await runPeriodicSyncLoop()
        }
        .refreshable { await runSync() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addMeal:
                AddGroupMealSheet(groupID: groupID, isManager: isManager, currentUserID: accountSession.currentUser?.id)
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

    // MARK: - Sections/rows

    @ViewBuilder
    private func daySection(_ date: Date) -> some View {
        Section {
            ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                slotContent(date: date, slot: slot)
            }
        } header: {
            HStack(spacing: 6) {
                Text(date.formatted(Date.weekdayFull))
                Text(date.formatted(Date.monthDay)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func slotContent(date: Date, slot: MealSlot) -> some View {
        let meals = visiblePlannedMeals.filter { $0.date.isSameDay(as: date) && $0.slot == slot }
        let slotSuggestions = visibleSuggestions
            .filter { $0.date.isSameDay(as: date) && $0.slot == slot }
            .sorted { $0.voteCount > $1.voteCount }

        if !meals.isEmpty || !slotSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(slot.displayName, systemImage: slot.symbolName)
                    .font(.brandCaption.bold())
                    .foregroundStyle(.secondary)
                ForEach(meals) { meal in
                    plannedMealRow(meal)
                }
                ForEach(slotSuggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func memberName(_ userID: String) -> String {
        group?.members.first(where: { $0.id == userID })?.displayNameOrPhoneNumber ?? "Someone"
    }

    private func iconName(isHomeCooked: Bool, isOrderingIn: Bool) -> String {
        if isHomeCooked { return "frying.pan" }
        return isOrderingIn ? "bag" : "fork.knife"
    }

    private func iconColor(isHomeCooked: Bool, isOrderingIn: Bool) -> Color {
        if isHomeCooked { return .brandForest }
        return isOrderingIn ? .brandHoney : .brandTerracotta
    }

    @ViewBuilder
    private func plannedMealRow(_ meal: GroupPlannedMeal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(isHomeCooked: meal.isHomeCooked, isOrderingIn: meal.isOrderingIn))
                .foregroundStyle(iconColor(isHomeCooked: meal.isHomeCooked, isOrderingIn: meal.isOrderingIn))
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.displayTitle).font(.brandSubheadline)
                Text("Decided by \(memberName(meal.decidedByUserID))")
                    .font(.brandCaption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if meal.syncState != .synced {
                pendingIndicator
            }
        }
        .swipeActions(edge: .trailing) {
            // MANAGER only — mirrors `DELETE /groups/:groupId/meal-plan/:id`
            // exactly (see routes/groupMealPlan.js).
            if isManager {
                Button(role: .destructive) { removePlannedMeal(meal) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: GroupMealSuggestion) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.displayTitle).font(.brandSubheadline)
                Text("Suggested by \(memberName(suggestion.proposedByUserID))")
                    .font(.brandCaption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if suggestion.syncState != .synced {
                pendingIndicator
            }
            // Voting is open to every member, regardless of role — mirrors
            // `POST .../suggestions/:id/vote`, which has no role gate at
            // all (see routes/groupMealPlan.js).
            Button {
                toggleVote(suggestion)
            } label: {
                Label("\(suggestion.voteCount)", systemImage: suggestion.votedByMe ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            // MANAGER only — mirrors `POST .../suggestions/:id/adopt`
            // exactly. Disabled while a prior sync couldn't reach the
            // server, since adopting is an immediate, online-only action
            // (see `GroupSyncService`'s "Known limitations" note on why).
            if isManager {
                Button("Use This") {
                    Task { await adopt(suggestion) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isKnownOffline || suggestion.isLocalPlaceholderID)
            }
        }
        .swipeActions(edge: .trailing) {
            // MANAGER, or the suggestion's own proposer — mirrors
            // `DELETE .../suggestions/:id` exactly (see
            // routes/groupMealPlan.js's own doc comment on that route).
            if isManager || suggestion.proposedByUserID == accountSession.currentUser?.id {
                Button(role: .destructive) { withdrawSuggestion(suggestion) } label: {
                    Label("Remove", systemImage: "trash")
                }
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

    /// A light re-sync every 25 seconds for as long as this screen is
    /// on-screen — plain `Task.sleep` loop inside the same `.task` this is
    /// awaited from, which SwiftUI cancels automatically the moment this
    /// view disappears (no separate `@State` task handle or explicit
    /// `.onDisappear` cleanup needed for that). 25s is frequent enough that
    /// a fellow member's change shows up without a manual pull-to-refresh
    /// during an active planning session, without hammering the backend
    /// for a household-scale, low-traffic feature.
    private func runPeriodicSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            await runSync()
        }
    }

    private func toggleVote(_ suggestion: GroupMealSuggestion) {
        suggestion.toggleVoteLocally()
        try? modelContext.save()
        Task { await runSync() }
    }

    private func removePlannedMeal(_ meal: GroupPlannedMeal) {
        if meal.isLocalPlaceholderID {
            // Never reached the server — nothing to tell it.
            modelContext.delete(meal)
        } else {
            meal.syncState = .pendingDelete
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    private func withdrawSuggestion(_ suggestion: GroupMealSuggestion) {
        if suggestion.isLocalPlaceholderID {
            modelContext.delete(suggestion)
        } else {
            suggestion.syncState = .pendingDelete
        }
        try? modelContext.save()
        Task { await runSync() }
    }

    private func adopt(_ suggestion: GroupMealSuggestion) async {
        do {
            try await GroupSyncService.adoptSuggestion(groupID: groupID, suggestionID: suggestion.id, modelContext: modelContext)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private enum ActiveSheet: Identifiable {
        case addMeal
        var id: String { "addMeal" }
    }
}

// MARK: - Add / suggest a meal

/// The "Add a Meal"/"Suggest a Meal" sheet — a `MANAGER` sees both "Add to
/// Plan" (decides directly) and "Suggest Instead"; a `PARTICIPANT` only
/// ever sees "Suggest for a Vote", same role split as the rest of this
/// screen. Both actions insert a `.pendingCreate` local row and dismiss
/// immediately — the actual `POST` happens on the next sync (see
/// `GroupSyncService.push`), so this works instantly offline too, same as
/// every other write in this feature.
private struct AddGroupMealSheet: View {
    let groupID: String
    let isManager: Bool
    let currentUserID: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = Calendar.current.startOfDay(for: .now)
    @State private var slot: MealSlot = .dinner
    @State private var kind: Kind = .recipe
    @State private var restaurantName = ""
    @State private var isOrderIn = false
    @State private var selectedRecipeID: String?
    @State private var selectedRecipeTitle: String?
    @State private var showRecipePicker = false

    private enum Kind: String, CaseIterable, Identifiable {
        case recipe = "Recipe"
        case restaurant = "Restaurant"
        var id: String { rawValue }
    }

    private var canSubmit: Bool {
        switch kind {
        case .recipe: return selectedRecipeID != nil
        case .restaurant: return !restaurantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Slot", selection: $slot) {
                        ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                }
                Section("What") {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .recipe:
                        Button {
                            showRecipePicker = true
                        } label: {
                            HStack {
                                Text(selectedRecipeTitle ?? "Choose a Recipe")
                                    .foregroundStyle(selectedRecipeTitle == nil ? .secondary : .primary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    case .restaurant:
                        TextField("Restaurant name", text: $restaurantName)
                        Toggle("Ordering in (not eating out)", isOn: $isOrderIn)
                    }
                }
                if currentUserID != nil {
                    Section {
                        if isManager {
                            Button("Add to Plan") { submit(asDecided: true) }
                                .disabled(!canSubmit)
                        }
                        Button(isManager ? "Suggest Instead (for a Vote)" : "Suggest for a Vote") {
                            submit(asDecided: false)
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .navigationTitle(isManager ? "Add a Meal" : "Suggest a Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showRecipePicker) {
                GroupRecipePickerSheet { id, title in
                    selectedRecipeID = id
                    selectedRecipeTitle = title
                }
            }
        }
    }

    private func submit(asDecided: Bool) {
        guard let currentUserID else { return }
        let recipeID = kind == .recipe ? selectedRecipeID : nil
        let restaurant = kind == .restaurant ? restaurantName.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        if asDecided {
            let meal = GroupPlannedMeal(
                id: GroupPlannedMeal.newLocalPlaceholderID(), groupID: groupID, date: date, slot: slot,
                recipeID: recipeID, cachedRecipeTitle: selectedRecipeTitle, restaurantName: restaurant,
                isOrderIn: isOrderIn, decidedByUserID: currentUserID, syncState: .pendingCreate
            )
            modelContext.insert(meal)
        } else {
            let suggestion = GroupMealSuggestion(
                id: GroupMealSuggestion.newLocalPlaceholderID(), groupID: groupID, date: date, slot: slot,
                recipeID: recipeID, cachedRecipeTitle: selectedRecipeTitle, restaurantName: restaurant,
                isOrderIn: isOrderIn, proposedByUserID: currentUserID, votedByMe: true, voteCount: 1,
                syncState: .pendingCreate
            )
            modelContext.insert(suggestion)
        }
        try? modelContext.save()
        dismiss()
    }
}

/// Picks a recipe from everything the caller can legally plan/suggest with
/// — their own recipe-library recipes, plus everything shared with them
/// (directly or via any group) — exactly the same owner/direct-share/
/// shared-group visibility check `routes/groupMealPlan.js`'s
/// `recipeVisibleToUser` enforces server-side (see that function's own doc
/// comment), so this picker can never offer a recipe the backend would
/// reject with a `400`. Deduped by recipe id: `GET /recipe-library/shared-with-me`
/// returns one entry PER SHARE (see `SharedRecipeEntry`'s own doc comment),
/// so the same recipe shared two different ways would otherwise appear
/// twice here.
private struct GroupRecipePickerSheet: View {
    let onPick: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recipes: [(id: String, title: String)] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredRecipes: [(id: String, title: String)] {
        guard !searchText.isEmpty else { return recipes }
        return recipes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && recipes.isEmpty {
                    ProgressView()
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                } else if recipes.isEmpty {
                    ContentUnavailableView(
                        "No Recipes Yet",
                        systemImage: "book",
                        description: Text("Only recipes you own, or that have been shared with you, can be planned here. Share one from Recipes first.")
                    )
                } else {
                    ForEach(filteredRecipes, id: \.id) { recipe in
                        Button {
                            onPick(recipe.id, recipe.title)
                            dismiss()
                        } label: {
                            Text(recipe.title).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText)
            .navigationTitle("Choose a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let mine = AccountsAPIClient.getMyRecipes()
            async let shared = AccountsAPIClient.getSharedRecipes()
            let (mineResult, sharedResult) = try await (mine, shared)
            var byID: [String: String] = [:]
            for recipe in mineResult { byID[recipe.id] = recipe.title }
            for entry in sharedResult { byID[entry.recipeID] = entry.title }
            recipes = byID.map { (id: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
