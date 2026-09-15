import SwiftUI
import SwiftData

/// "Add Groceries" — the single entry point for every way to put something
/// onto a group's shared grocery list, replacing three sections that used
/// to sit always-open on the main list at once (a quick-add field aside —
/// that one stays, see `GroupSharedGroceryListView.quickAddField`'s own
/// doc comment for why). Direct user feedback, with a reference screenshot
/// of another app's flow attached: the old layout — the main list, then an
/// always-expanded "Suggested From Your Cooking List" (day-strip, Generate
/// button, and the whole review queue all inline) and an always-expanded
/// "From Your Household Groceries" list, all visible on screen at once —
/// "is not that good right now and very confusing." This collapses all of
/// that behind one button and a short, three-option flow instead, while
/// keeping every underlying capability: typing a plain item (`AddItemSearchView`,
/// which still opens the existing full add-item form for anyone who wants
/// to set a quantity/category/section up front), generating ingredients
/// from planned meals (`CookingListDaysView` -> `ReviewIngredientsView`,
/// the exact same `GroupGroceryListBuilder` resolution the old day-strip
/// used), and quick-adding from your own personal "Household Groceries"
/// catalog, now called "My Usuals" here to match the reference and tabbed
/// by category (`MyUsualsPickerView`).
///
/// **Role gating carries over unchanged**: every commit path here (`AddItemSearchView
/// .submit`, `ReviewIngredientsView.commit`, `MyUsualsPickerView.commit`)
/// uses the exact same MANAGER-adds-directly/PARTICIPANT-suggests split as
/// every other add path on `GroupSharedGroceryListView` — see that view's
/// own top-level doc comment on role gating. The one real behavior change:
/// `ReviewIngredientsView`'s checkbox-and-quantity review step is itself
/// the "someone looked at this before it's real" safeguard the old
/// `GroupGroceryListBuilder.generate(...)` needed an always-`.suggested`,
/// manager-must-separately-accept queue for — with a genuine review step
/// now built into the flow, a MANAGER's reviewed picks can go straight onto
/// the real list like any other direct add, rather than still landing in a
/// second queue to review a second time. See `GroupGroceryListBuilder
/// .resolveCandidates`'s own doc comment for the fuller reasoning.
///
/// One shared `NavigationPath`, not a chain of independent `NavigationLink`s
/// — `GroceriesAddedConfirmationView`'s "Add More Items" needs to pop all
/// the way back to this sheet's own root from up to three pushes deep
/// (day/meal picker -> review -> confirmation, or usuals picker ->
/// confirmation), which only a shared, externally-resettable path makes
/// possible.
struct AddGroceriesSheet: View {
    let groupID: String
    let isManager: Bool
    let isKnownOffline: Bool

    @Environment(\.dismiss) private var dismissSheet
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: AddGroceriesDestination.addItem) {
                        AddGroceriesOptionRow(
                            icon: "magnifyingglass",
                            title: "Add an Item",
                            subtitle: isManager ? "Search or type to add anything" : "Search or type to suggest anything"
                        )
                    }
                    NavigationLink(value: AddGroceriesDestination.cookingListDays) {
                        AddGroceriesOptionRow(
                            icon: "fork.knife",
                            title: "From Your Cooking List",
                            subtitle: "Add ingredients from meals you've planned"
                        )
                    }
                    NavigationLink(value: AddGroceriesDestination.myUsuals) {
                        AddGroceriesOptionRow(
                            icon: "bookmark.fill",
                            title: "From My Usuals",
                            subtitle: "Quickly add things you regularly buy"
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to Your Grocery List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismissSheet() }
                }
            }
            .navigationDestination(for: AddGroceriesDestination.self) { destination in
                switch destination {
                case .addItem:
                    AddItemSearchView(groupID: groupID, isManager: isManager)
                case .cookingListDays:
                    CookingListDaysView(groupID: groupID, isManager: isManager, isKnownOffline: isKnownOffline, path: $path)
                case .reviewIngredients(let candidates):
                    ReviewIngredientsView(groupID: groupID, isManager: isManager, candidates: candidates, path: $path)
                case .myUsuals:
                    MyUsualsPickerView(groupID: groupID, isManager: isManager, path: $path)
                case .confirmation(let count, let isSuggestion):
                    // `dismissSheet` (a `DismissAction`) isn't implicitly
                    // convertible to a `() -> Void` closure parameter even
                    // though it's callable via `callAsFunction` — wrapped
                    // explicitly rather than passed as a bare value.
                    GroceriesAddedConfirmationView(count: count, isSuggestion: isSuggestion, path: $path, onViewList: { dismissSheet() })
                }
            }
        }
    }
}

/// Every screen `AddGroceriesSheet.path` can push to. `Hashable` (not
/// `Codable`) is all `NavigationPath` needs — see `GroupGroceryListBuilder
/// .Candidate`'s own doc comment for why that type also conforms.
private enum AddGroceriesDestination: Hashable {
    case addItem
    case cookingListDays
    case reviewIngredients([GroupGroceryListBuilder.Candidate])
    case myUsuals
    case confirmation(count: Int, isSuggestion: Bool)
}

private struct AddGroceriesOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.brandTitle3)
                .foregroundStyle(Color.brandForest)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.brandHeadline)
                Text(subtitle).font(.brandCaption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - "Add an Item" (search/type, name-only quick add)

/// A search-styled, name-only quick add — direct port of
/// `GroupSharedGroceryListView.quickAddField`'s own submit logic, just given
/// its own full screen (reached from the "Add Groceries" flow) instead of
/// living inline at the top of the main list, per Q2's "simple reskin"
/// scope call: the shared group list has no real product-variant catalog
/// (rating/photos/brand options) the way the reference screenshot's search
/// results imply — building one would mean growing the group data model a
/// concept it doesn't have today. "Add a Custom Item" below still opens the
/// existing, more detailed `AddGroupGroceryItemSheet` (quantity/category/
/// section) for anyone who wants more control than a bare name gives.
private struct AddItemSearchView: View {
    let groupID: String
    let isManager: Bool

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @State private var name = ""
    @State private var recentlyAdded: [String] = []
    @State private var showCustomItemSheet = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(isManager ? "Type an item name" : "Type an item to suggest", text: $name)
                        .submitLabel(.done)
                        .onSubmit(submit)
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: submit) {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandForest)
                    }
                }
            } footer: {
                Text("Press Return to add it \u{2014} keep typing to add more, one after another.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }

            if !recentlyAdded.isEmpty {
                Section("Just Added") {
                    ForEach(recentlyAdded, id: \.self) { addedName in
                        Label(addedName.titleCasedForDisplay, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.brandForest)
                    }
                }
            }

            Section {
                Button {
                    showCustomItemSheet = true
                } label: {
                    Label("Add a Custom Item", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Can't find what you're looking for, or want to set a quantity or category up front? Add a custom item instead.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add an Item")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCustomItemSheet) {
            AddGroupGroceryItemSheet(groupID: groupID, isManager: isManager)
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        recentlyAdded.insert(trimmedName, at: 0)
        name = ""
        Task { _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext) }
    }
}

// MARK: - "From Your Cooking List" step 1: pick days/meals

/// Restores the exact day-strip + "which days" picker the old, always-open
/// "Suggested From Your Cooking List" section had, plus one refinement the
/// reference screenshot showed that the old section didn't have at all: a
/// checkbox per individual meal on the selected days, so a day with two
/// planned meals doesn't force pulling ingredients from both. Defaults to
/// every home-cooked meal on the selected days included (`deselectedMealIDs`
/// starts empty) — the same "everything on these days" behavior the old
/// section always had, with this screen's checkboxes only adding an
/// opt-OUT, never changing the default outcome of just picking days.
private struct CookingListDaysView: View {
    let groupID: String
    let isManager: Bool
    let isKnownOffline: Bool
    @Binding var path: NavigationPath

    @Query private var plannedMeals: [GroupPlannedMeal]
    @Query private var existingItems: [GroupSharedGroceryItem]

    @State private var selectedDates: Set<Date> = CookingListDaysView.defaultDates()
    @State private var deselectedMealIDs: Set<String> = []
    @State private var isGenerating = false
    @State private var errorMessage: String?

    init(groupID: String, isManager: Bool, isKnownOffline: Bool, path: Binding<NavigationPath>) {
        self.groupID = groupID
        self.isManager = isManager
        self.isKnownOffline = isKnownOffline
        self._path = path
        // Same captured-local-constant `#Predicate` caution as every other
        // group-scoped `@Query` in this app — see `GroupSharedMealPlanView
        // .init`'s own comment.
        let gid = groupID
        _plannedMeals = Query(filter: #Predicate<GroupPlannedMeal> { $0.groupID == gid }, sort: \GroupPlannedMeal.date)
        _existingItems = Query(filter: #Predicate<GroupSharedGroceryItem> { $0.groupID == gid })
    }

    private static func defaultDates() -> Set<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) })
    }

    private static let windowInDays = 21

    private var windowDays: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<Self.windowInDays).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private var visibleMeals: [GroupPlannedMeal] {
        plannedMeals.filter { $0.syncState != .pendingDelete }
    }

    /// Only home-cooked meals on a selected day — a restaurant/order-in
    /// meal contributes no ingredients, same rule `GroupGroceryListBuilder`
    /// itself already applies (see that type's own doc comment).
    private var mealsOnSelectedDays: [GroupPlannedMeal] {
        visibleMeals
            .filter { $0.isHomeCooked && selectedDates.contains(Calendar.current.startOfDay(for: $0.date)) }
            .sorted { $0.date < $1.date }
    }

    private var mealsByDay: [(Date, [GroupPlannedMeal])] {
        Dictionary(grouping: mealsOnSelectedDays) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key < $1.key }
    }

    private var includedMeals: [GroupPlannedMeal] {
        mealsOnSelectedDays.filter { !deselectedMealIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    dayStrip
                    HStack {
                        Text("\(selectedDates.count) day\(selectedDates.count == 1 ? "" : "s") selected")
                            .font(.brandCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { selectedDates.removeAll() }
                            .font(.brandCaption)
                            .disabled(selectedDates.isEmpty)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Choose which days to add ingredients from")
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            }

            if !mealsOnSelectedDays.isEmpty {
                ForEach(mealsByDay, id: \.0) { day, meals in
                    Section {
                        ForEach(meals) { meal in
                            Button {
                                toggleMeal(meal)
                            } label: {
                                HStack {
                                    Image(systemName: deselectedMealIDs.contains(meal.id) ? "square" : "checkmark.square.fill")
                                        .foregroundStyle(deselectedMealIDs.contains(meal.id) ? Color.secondary : Color.brandForest)
                                    Text(meal.displayTitle).foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(day.formatted(Date.weekdayFull)), \(day.formatted(Date.monthDay))")
                    }
                }
            } else if !selectedDates.isEmpty {
                Section {
                    Text("No home-cooked meals planned on the selected days.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("From Your Cooking List")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if isKnownOffline {
                    Text("Resolving ingredients needs a connection \u{2014} try again once you're back online.")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                    } else {
                        Text("Generate Ingredients").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandForest)
                .controlSize(.large)
                .disabled(includedMeals.isEmpty || isGenerating || isKnownOffline)
            }
            .padding()
            .background(.bar)
        }
    }

    /// Same visuals/behavior as the removed `GroupSharedGroceryListView
    /// .suggestionDayStrip` this replaces — smaller day chips, independent
    /// per-day toggling (not a contiguous range), same reasoning as that
    /// property's own doc comment.
    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(windowDays, id: \.self) { day in
                    let normalized = Calendar.current.startOfDay(for: day)
                    let isSelected = selectedDates.contains(normalized)
                    Button {
                        if isSelected {
                            selectedDates.remove(normalized)
                        } else {
                            selectedDates.insert(normalized)
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 9))
                            Text(day.formatted(.dateTime.day())).font(.brandCallout.bold())
                        }
                        .frame(width: 36, height: 42)
                        .background(isSelected ? Color.brandForest : Color.secondary.opacity(0.12))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggleMeal(_ meal: GroupPlannedMeal) {
        if deselectedMealIDs.contains(meal.id) {
            deselectedMealIDs.remove(meal.id)
        } else {
            deselectedMealIDs.insert(meal.id)
        }
    }

    private func generate() async {
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        let candidates = await GroupGroceryListBuilder.resolveCandidates(
            plannedMeals: includedMeals,
            existingItems: existingItems.filter { $0.syncState != .pendingDelete }
        )
        if candidates.isEmpty {
            errorMessage = "Nothing new to add from those meals \u{2014} their ingredients might already be on your list, or those recipes don't have any saved."
        } else {
            path.append(AddGroceriesDestination.reviewIngredients(candidates))
        }
    }
}

// MARK: - "From Your Cooking List" step 2: review ingredients

/// Checkbox-and-quantity review of what `CookingListDaysView.generate()`
/// resolved, grouped by category like the main list's own "By Category"
/// view — every candidate starts checked (uncheck what you don't want) with
/// a `[-] N [+]` purchase-count stepper defaulted to 1, same convention as
/// `GroupGroceryItemRow`'s own stepper on the live list. See this type's
/// own `commit()` for what happens to a checked candidate once "Add ... to
/// Grocery List" is tapped.
private struct ReviewIngredientsView: View {
    let groupID: String
    let isManager: Bool
    let candidates: [GroupGroceryListBuilder.Candidate]
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @State private var deselectedKeys: Set<String> = []
    @State private var counts: [String: Int] = [:]
    @State private var isSaving = false

    private func key(for candidate: GroupGroceryListBuilder.Candidate) -> String {
        GroceryListBuilder.canonicalKey(for: candidate.displayName)
    }

    private var candidatesByCategory: [(GroceryCategory, [GroupGroceryListBuilder.Candidate])] {
        Dictionary(grouping: candidates, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { ($0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
    }

    private var selectedCount: Int { candidates.count - deselectedKeys.count }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("\(candidates.count) ingredient\(candidates.count == 1 ? "" : "s") found")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(deselectedKeys.isEmpty ? "Deselect All" : "Select All") {
                        deselectedKeys = deselectedKeys.isEmpty ? Set(candidates.map(key(for:))) : []
                    }
                    .font(.brandCaption.bold())
                }
            }
            ForEach(candidatesByCategory, id: \.0) { category, items in
                Section(category.displayName) {
                    ForEach(items, id: \.displayName) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
        .navigationTitle("Suggested Ingredients")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await commit() }
            } label: {
                if isSaving {
                    HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                } else {
                    Text("Add \(selectedCount) Item\(selectedCount == 1 ? "" : "s") to Grocery List")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandForest)
            .controlSize(.large)
            .disabled(selectedCount == 0 || isSaving)
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: GroupGroceryListBuilder.Candidate) -> some View {
        let itemKey = key(for: candidate)
        let isSelected = !deselectedKeys.contains(itemKey)
        HStack {
            Button {
                if isSelected {
                    deselectedKeys.insert(itemKey)
                } else {
                    deselectedKeys.remove(itemKey)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.brandForest : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName.titleCasedForDisplay)
                if !candidate.quantityText.isEmpty {
                    Text(candidate.quantityText).font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                ReviewQuantityStepper(count: Binding(
                    get: { counts[itemKey] ?? 1 },
                    set: { counts[itemKey] = $0 }
                ))
            }
        }
    }

    /// A checked candidate lands straight on the real list for a MANAGER
    /// (`.thisWeek`) — this review screen's own checkboxes ARE the "someone
    /// looked at this before it's real" step, so there's no reason to also
    /// queue it in `.suggested` for a second, separate accept. A
    /// PARTICIPANT's picks still land as `.suggested`, matching the exact
    /// role split every other add path on this screen already uses — see
    /// this file's own top-level doc comment.
    private func commit() async {
        guard let currentUserID = accountSession.currentUser?.id else { return }
        isSaving = true
        defer { isSaving = false }
        var addedCount = 0
        for candidate in candidates {
            let itemKey = key(for: candidate)
            guard !deselectedKeys.contains(itemKey) else { continue }
            let item = GroupSharedGroceryItem(
                id: GroupSharedGroceryItem.newLocalPlaceholderID(),
                groupID: groupID,
                name: candidate.displayName,
                category: candidate.category,
                section: isManager ? .thisWeek : .suggested,
                quantityText: candidate.quantityText,
                quantityCount: counts[itemKey] ?? 1,
                addedByUserID: currentUserID,
                syncState: .pendingCreate
            )
            modelContext.insert(item)
            addedCount += 1
        }
        try? modelContext.save()
        _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext)
        path.append(AddGroceriesDestination.confirmation(count: addedCount, isSuggestion: !isManager))
    }
}

/// A `[-] N [+]` purchase-count control for a candidate not yet inserted —
/// same visuals as `GroupSharedGroceryListView`'s own private
/// `GroupQuantityStepper`, duplicated (not shared) since that one routes
/// changes through `GroupSharedGroceryListView.setQuantityCount`'s sync
/// bookkeeping, which doesn't apply here (nothing's been inserted yet).
private struct ReviewQuantityStepper: View {
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Button { count = max(1, count - 1) } label: { Image(systemName: "minus.circle") }
            Text("\(count)").font(.brandCaption).monospacedDigit().frame(minWidth: 16)
            Button { count += 1 } label: { Image(systemName: "plus.circle") }
        }
        .foregroundStyle(Color.brandForest)
        .buttonStyle(.plain)
    }
}

// MARK: - "From My Usuals"

/// The reference screenshot's category-tabbed, multi-select "My Usuals"
/// picker — the same personal, per-device `HistoricalGroceryItem` catalog
/// `GroupSharedGroceryListView`'s old, always-open "From Your Household
/// Groceries" section read (see that model's own doc comment for why it's
/// deliberately never synced/shared), just tabbed by category and
/// multi-select instead of one Add button per row. The search field
/// doubles as "add a new usual" — same capability the old section's own
/// type-to-add field had — when nothing already in the catalog matches it.
private struct MyUsualsPickerView: View {
    let groupID: String
    let isManager: Bool
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query(sort: \HistoricalGroceryItem.name) private var myHouseholdItems: [HistoricalGroceryItem]
    @Query private var existingItems: [GroupSharedGroceryItem]

    @State private var searchText = ""
    @State private var selectedCategory: GroceryCategory?
    @State private var selectedNames: Set<String> = []
    @State private var isSaving = false

    init(groupID: String, isManager: Bool, path: Binding<NavigationPath>) {
        self.groupID = groupID
        self.isManager = isManager
        self._path = path
        let gid = groupID
        _existingItems = Query(filter: #Predicate<GroupSharedGroceryItem> { $0.groupID == gid })
    }

    private var presentCategories: [GroceryCategory] {
        Array(Set(myHouseholdItems.map(\.category))).sorted { $0.sortIndex < $1.sortIndex }
    }

    private var filteredItems: [HistoricalGroceryItem] {
        myHouseholdItems.filter { item in
            (selectedCategory == nil || item.category == selectedCategory)
                && (searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func alreadyInList(_ item: HistoricalGroceryItem) -> Bool {
        let key = GroceryListBuilder.canonicalKey(for: item.name)
        return existingItems.contains { $0.syncState != .pendingDelete && GroceryListBuilder.canonicalKey(for: $0.name) == key }
    }

    private var exactMatchExists: Bool {
        let key = GroceryListBuilder.canonicalKey(for: searchText)
        return myHouseholdItems.contains { GroceryListBuilder.canonicalKey(for: $0.name) == key }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            categoryTabs
            List {
                if filteredItems.isEmpty {
                    Text(myHouseholdItems.isEmpty
                        ? "Nothing in My Usuals yet \u{2014} type a name above to add one."
                        : "No matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredItems) { item in
                        usualRow(item)
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("From My Usuals")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await commit() }
            } label: {
                if isSaving {
                    HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                } else {
                    Text(selectedNames.isEmpty ? "Add to List" : "Add \(selectedNames.count) to List")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandForest)
            .controlSize(.large)
            .disabled(selectedNames.isEmpty || isSaving)
            .padding()
            .background(.bar)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search My Usuals", text: $searchText)
                .submitLabel(.done)
                .onSubmit(addNewUsualIfNeeded)
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exactMatchExists {
                Button(action: addNewUsualIfNeeded) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandForest)
                .accessibilityLabel("Add \"\(searchText)\" to My Usuals")
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 12)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryTabButton(nil, title: "All")
                ForEach(presentCategories) { category in
                    categoryTabButton(category, title: category.displayName)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func categoryTabButton(_ category: GroceryCategory?, title: String) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            Text(title)
                .font(.brandCaption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.brandForest : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func usualRow(_ item: HistoricalGroceryItem) -> some View {
        let inList = alreadyInList(item)
        let isSelected = selectedNames.contains(item.name)
        Button {
            guard !inList else { return }
            if isSelected {
                selectedNames.remove(item.name)
            } else {
                selectedNames.insert(item.name)
            }
        } label: {
            HStack {
                Image(systemName: inList ? "checkmark.circle.fill" : (isSelected ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(inList ? Color.secondary : Color.brandForest)
                Text(item.name.titleCasedForDisplay)
                    .foregroundStyle(inList ? .secondary : .primary)
                Spacer()
                if inList {
                    Text("On List").font(.brandCaption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(inList)
    }

    /// Same canonical-name dedupe as the removed `GroupSharedGroceryListView
    /// .submitHouseholdQuickAdd` this replaces — typing a name already in
    /// the catalog is a harmless no-op, not a visible duplicate row.
    private func addNewUsualIfNeeded() {
        let trimmedName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !exactMatchExists else { return }
        modelContext.insert(HistoricalGroceryItem(name: trimmedName))
        searchText = ""
    }

    private func commit() async {
        guard let currentUserID = accountSession.currentUser?.id else { return }
        isSaving = true
        defer { isSaving = false }
        var addedCount = 0
        for item in myHouseholdItems where selectedNames.contains(item.name) && !alreadyInList(item) {
            let groceryItem = GroupSharedGroceryItem(
                id: GroupSharedGroceryItem.newLocalPlaceholderID(),
                groupID: groupID,
                name: item.name,
                category: item.category,
                section: isManager ? .thisWeek : .suggested,
                addedByUserID: currentUserID,
                syncState: .pendingCreate
            )
            modelContext.insert(groceryItem)
            addedCount += 1
        }
        try? modelContext.save()
        _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext)
        path.append(AddGroceriesDestination.confirmation(count: addedCount, isSuggestion: !isManager))
    }
}

// MARK: - Confirmation

/// The reference screenshot's "N items added" success screen — shown after
/// `ReviewIngredientsView`/`MyUsualsPickerView` commit (not after
/// `AddItemSearchView`, which is a live add-as-you-go screen with no single
/// "batch" to confirm). Wording adapts to whether these actually landed on
/// the real list or went into the `.suggested` queue for a MANAGER to
/// review — see this file's own top-level doc comment on why a
/// PARTICIPANT's picks still take that second path.
private struct GroceriesAddedConfirmationView: View {
    let count: Int
    let isSuggestion: Bool
    @Binding var path: NavigationPath
    /// Dismisses `AddGroceriesSheet` entirely — passed down from its own
    /// `@Environment(\.dismiss)` rather than this view reading its own,
    /// since `dismiss` called from a screen pushed several levels deep in a
    /// `NavigationStack` only pops one level by default, not the sheet
    /// itself.
    let onViewList: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.brandForest)
            VStack(spacing: 6) {
                Text(isSuggestion
                    ? "\(count) item\(count == 1 ? "" : "s") suggested"
                    : "\(count) item\(count == 1 ? "" : "s") added")
                    .font(.brandTitle2.bold())
                Text(isSuggestion
                    ? "Sent to a manager to review before they're on the real list."
                    : "Added straight to your grocery list.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 10) {
                Button("View Grocery List", action: onViewList)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Add More Items") {
                    path = NavigationPath()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .navigationBarBackButtonHidden(true)
    }
}
