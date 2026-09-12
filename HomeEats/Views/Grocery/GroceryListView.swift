import SwiftUI
import SwiftData
import UIKit

private enum GroceryViewMode: String, CaseIterable, Identifiable {
    case byCategory = "By Category"
    case myLayout = "My Layout"
    var id: String { rawValue }
}

struct GroceryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlannedMeal.date) private var allPlannedMeals: [PlannedMeal]
    @Query private var staples: [StapleItem]
    @Query private var allProductOptions: [ProductOption]
    @Query private var allGroceryItems: [GroceryItem]
    @Query(sort: \StoreAisle.sortIndex) private var aisles: [StoreAisle]
    @Query private var aisleAssignments: [ItemAisleAssignment]
    @Query(sort: \HistoricalGroceryItem.name) private var historicalItems: [HistoricalGroceryItem]

    @State private var viewMode: GroceryViewMode = .byCategory
    @State private var showStaplesManager = false
    @State private var showAddItemSheet = false
    @State private var showAislesManager = false
    @State private var showHistoryImport = false
    @State private var productPickerItem: GroceryItem?
    // The only two collapsible sections on this screen — everything else
    // (the grocery list itself, its per-category groupings) stays always
    // visible. Default expanded so nothing looks hidden the first time you
    // land here; either can be tapped closed once you don't need it.
    @State private var suggestionsExpanded = true
    @State private var pastGroceriesExpanded = true
    // The date range "Generate Suggestions" pulls planned meals from —
    // defaults to the week ahead, but this is meant to be adjusted, e.g. to
    // just the days after whatever you're already stocked through.
    @State private var suggestionRangeStart = Calendar.current.startOfDay(for: .now)
    @State private var suggestionRangeEnd = Calendar.current.date(
        byAdding: .day, value: 6, to: Calendar.current.startOfDay(for: .now)
    ) ?? .now

    private var calendar: Calendar { Calendar.current }

    /// Every grocery item, full stop — the list is one persistent, standing
    /// list rather than something regenerated fresh per calendar week, so
    /// nothing here is scoped by date.
    private var items: [GroceryItem] { allGroceryItems }

    /// Everything actually "on the list" to buy — accepted recipe
    /// ingredients plus staples — as opposed to `.suggested` (still pending
    /// a decision) or `.rejected` (explicitly not needed). Staples used to
    /// get their own separate "Staples" section, grouped by category same
    /// as everything else — which just duplicated every category header a
    /// second time. Merging them into one set of category groups here means
    /// each category (e.g. "Produce") appears once, with both recipe items
    /// and standing staples in it together.
    private var purchasableItems: [GroceryItem] {
        items.filter { $0.section == .thisWeek || $0.section == .staples }
    }
    private var purchasableByCategory: [(GroceryCategory, [GroceryItem])] {
        grouped(purchasableItems)
    }
    /// Pulled from a chosen meal-plan date range (or a standing staple),
    /// awaiting an Add/Reject decision — see `GroceryListSection.suggested`.
    private var suggestedItems: [GroceryItem] {
        items.filter { $0.section == .suggested }.sorted { $0.name < $1.name }
    }
    private var rejectedItems: [GroceryItem] {
        items.filter { $0.section == .rejected }.sorted { $0.name < $1.name }
    }

    private func grouped(_ items: [GroceryItem]) -> [(GroceryCategory, [GroceryItem])] {
        Dictionary(grouping: items, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { ($0.key, $0.value.sorted { $0.orderIndex < $1.orderIndex }) }
    }

    var body: some View {
        List {
            Section {
                Picker("View", selection: $viewMode) {
                    ForEach(GroceryViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            Section {
            } header: {
                groceryListTitleHeader
            }

            if viewMode == .byCategory {
                byCategorySections
            } else {
                myLayoutSections
            }

            suggestionsSection

            pastGroceriesSection
        }
        // Reorder handles (via `.onMove` below) only ever show up on rows
        // inside a section that actually declares `.onMove` — leaving this
        // on permanently means there's always exactly one, persistent way
        // to reorder a category/aisle's items without an extra "Edit" tap
        // first, and no second, competing handle layered on top of it.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Grocery List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
            // A direct "+" for the single most common action (adding one
            // item by hand), rather than burying it a level deep inside the
            // "•••" menu with the less-frequent management screens.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddItemSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showStaplesManager = true
                    } label: {
                        Label("Manage Staples", systemImage: "list.bullet.clipboard")
                    }
                    Button {
                        showAislesManager = true
                    } label: {
                        Label("Manage My Aisles", systemImage: "square.grid.2x2")
                    }
                    Button {
                        showHistoryImport = true
                    } label: {
                        Label("Add Past Groceries…", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showStaplesManager) {
            StaplesManagerView()
        }
        .sheet(isPresented: $showAddItemSheet) {
            AddGroceryItemSheet()
        }
        .sheet(isPresented: $showAislesManager) {
            AislesManagerView()
        }
        .sheet(isPresented: $showHistoryImport) {
            GroceryHistoryImportSheet()
        }
        .sheet(item: $productPickerItem) { item in
            ProductOptionPickerView(genericItemName: item.name) { chosen in
                item.selectedProductOptionID = chosen?.id
            }
        }
        // Keeps active staples surfaced as pending suggestions any time the
        // tab is opened, without needing a manual "generate" step — only
        // staples flow through here; meal-plan ingredients are pulled in
        // deliberately, for whatever date range is chosen below.
        .task {
            refreshStaples()
        }
    }

    // MARK: - Suggested (from a chosen meal-plan range, pending Add/Reject)

    /// One collapsible section — not one dropdown per sub-group — covering
    /// the date-range picker that drives what gets suggested, the pending
    /// suggestions themselves, and anything already rejected out of them.
    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $suggestionsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick the dates you want to plan groceries for — handy for covering just what's ahead, e.g. Wednesday through next Tuesday if you're already stocked through this Tuesday.")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                    DatePicker("From", selection: $suggestionRangeStart, displayedComponents: .date)
                        .onChange(of: suggestionRangeStart) { _, newValue in
                            if suggestionRangeEnd < newValue { suggestionRangeEnd = newValue }
                        }
                    DatePicker("To", selection: $suggestionRangeEnd, in: suggestionRangeStart..., displayedComponents: .date)
                    Button {
                        generateSuggestions()
                    } label: {
                        Label("Generate Suggestions", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                }
                .padding(.vertical, 6)

                if !suggestedItems.isEmpty {
                    Button("Add All", action: acceptAllSuggested)
                        .font(.brandCallout.bold())
                        .foregroundStyle(Color.brandForest)
                    ForEach(suggestedItems) { item in
                        GrocerySuggestionRow(
                            name: item.name,
                            quantityText: item.quantityText,
                            isSecondary: false,
                            addIsDisabled: false,
                            onAdd: { accept(item) },
                            onReject: { reject(item) }
                        )
                    }
                }
                if !rejectedItems.isEmpty {
                    Text("Rejected")
                        .font(.brandCallout.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, suggestedItems.isEmpty ? 0 : 6)
                    ForEach(rejectedItems) { item in
                        GrocerySuggestionRow(
                            name: item.name,
                            quantityText: item.quantityText,
                            isSecondary: true,
                            addIsDisabled: false,
                            onAdd: { accept(item) },
                            onReject: nil
                        )
                    }
                }
            } label: {
                majorHeader("Suggestions From Your Meal Plan")
            }
        } footer: {
            Text("Pulled from your meal plan for the dates you pick, plus your active staples. Add what you actually need to buy, or reject anything you already have on hand — you can always add a rejected item back later.")
        }
    }

    private func accept(_ item: GroceryItem) {
        item.section = .thisWeek
    }

    private func reject(_ item: GroceryItem) {
        item.section = .rejected
    }

    private func acceptAllSuggested() {
        for item in suggestedItems { item.section = .thisWeek }
    }

    private func generateSuggestions() {
        let start = calendar.startOfDay(for: suggestionRangeStart)
        let end = calendar.startOfDay(for: suggestionRangeEnd)
        let mealsInRange = allPlannedMeals.filter { meal in
            let day = calendar.startOfDay(for: meal.date)
            return day >= start && day <= end
        }
        GroceryListBuilder.regenerate(plannedMeals: mealsInRange, staples: staples, in: modelContext)
    }

    private func refreshStaples() {
        GroceryListBuilder.regenerate(plannedMeals: [], staples: staples, in: modelContext)
    }

    // MARK: - By category (default) view

    @ViewBuilder
    private var byCategorySections: some View {
        if !purchasableByCategory.isEmpty {
            ForEach(Array(purchasableByCategory.enumerated()), id: \.element.0) { index, entry in
                let (category, categoryItems) = entry
                Section {
                    ForEach(categoryItems) { item in
                        row(for: item)
                            .contextMenu { moveToCategoryMenu(for: item) }
                    }
                    .onMove { source, destination in
                        moveWithinCategory(categoryItems, from: source, to: destination)
                    }
                } header: {
                    Text(category.displayName)
                } footer: {
                    // Only shown once, under the last category section,
                    // rather than repeated under every one.
                    if index == purchasableByCategory.count - 1 {
                        Text("Drag the ≡ handle to reorder within a category. Touch and hold an item to move it to a different category for good. Manage your standing staples from the toolbar.")
                    }
                }
            }
        } else {
            Section {
                Text("Nothing on your list yet. Add a staple from the toolbar, or generate suggestions from your meal plan below.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reassigns `orderIndex` for every item in one category after a
    /// same-category reorder — the whole category's order is rewritten
    /// every time rather than fractionally slotting just the moved item in,
    /// which keeps this simple and exactly matches what `.onMove` reports.
    private func moveWithinCategory(_ categoryItems: [GroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = categoryItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
        }
    }

    private func moveToCategory(_ item: GroceryItem, _ category: GroceryCategory) {
        guard item.category != category else { return }
        item.category = category
        item.categoryManuallySet = true
        // Lands at the end of its new category, same spot a freshly
        // generated item would — not some arbitrary/undefined position.
        let maxIndex = purchasableItems.filter { $0.category == category }.map(\.orderIndex).max() ?? 0
        item.orderIndex = maxIndex + 1
    }

    @ViewBuilder
    private func moveToCategoryMenu(for item: GroceryItem) -> some View {
        Menu {
            ForEach(GroceryCategory.allCases) { category in
                Button {
                    moveToCategory(item, category)
                } label: {
                    if category == item.category {
                        Label(category.displayName, systemImage: "checkmark")
                    } else {
                        Text(category.displayName)
                    }
                }
            }
        } label: {
            Label("Move to Category", systemImage: "folder")
        }
    }

    // MARK: - "My Grocery Layout" view

    @ViewBuilder
    private var myLayoutSections: some View {
        // Aisle layout is only meaningful for things you're actually
        // buying — a still-pending suggestion or something you rejected
        // shouldn't show up sorted into an aisle.
        let unassigned = purchasableItems.filter { aisleID(for: $0) == nil }

        Section {
            if unassigned.isEmpty {
                Text("Everything's sorted into an aisle.").foregroundStyle(.secondary)
            }
            ForEach(unassigned) { item in
                row(for: item)
                    .contextMenu { moveToAisleMenu(for: item) }
            }
            .onMove { source, destination in
                moveWithinAisle(unassigned, from: source, to: destination)
            }
        } header: {
            Text("Unsorted")
        } footer: {
            Text(aisles.isEmpty
                 ? "Add your store's aisles from the toolbar, then touch and hold an item to place it there."
                 : "Touch and hold an item to place it into an aisle below for good.")
        }

        ForEach(aisles) { aisle in
            let aisleItems = purchasableItems.filter { aisleID(for: $0) == aisle.id }
            Section(aisle.name) {
                if aisleItems.isEmpty {
                    Text("Touch and hold an item above to move it here.").font(.brandCaption).foregroundStyle(.tertiary)
                }
                ForEach(aisleItems) { item in
                    row(for: item)
                        .contextMenu { moveToAisleMenu(for: item) }
                }
                .onMove { source, destination in
                    moveWithinAisle(aisleItems, from: source, to: destination)
                }
            }
        }
    }

    private func moveWithinAisle(_ aisleItems: [GroceryItem], from source: IndexSet, to destination: Int) {
        var reordered = aisleItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
        }
    }

    @ViewBuilder
    private func moveToAisleMenu(for item: GroceryItem) -> some View {
        Menu {
            Button {
                unassign([item.name])
            } label: {
                if aisleID(for: item) == nil {
                    Label("Unsorted", systemImage: "checkmark")
                } else {
                    Text("Unsorted")
                }
            }
            ForEach(aisles) { aisle in
                Button {
                    assign([item.name], to: aisle)
                } label: {
                    if aisleID(for: item) == aisle.id {
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

    private func aisleID(for item: GroceryItem) -> UUID? {
        let key = GroceryListBuilder.canonicalKey(for: item.name)
        return aisleAssignments.first { GroceryListBuilder.canonicalKey(for: $0.canonicalItemName) == key }?.aisleID
    }

    private func assign(_ names: [String], to aisle: StoreAisle) {
        for name in names {
            let key = GroceryListBuilder.canonicalKey(for: name)
            if let existing = aisleAssignments.first(where: { GroceryListBuilder.canonicalKey(for: $0.canonicalItemName) == key }) {
                existing.aisleID = aisle.id
            } else {
                modelContext.insert(ItemAisleAssignment(canonicalItemName: name, aisleID: aisle.id))
            }
        }
    }

    private func unassign(_ names: [String]) {
        for name in names {
            let key = GroceryListBuilder.canonicalKey(for: name)
            if let existing = aisleAssignments.first(where: { GroceryListBuilder.canonicalKey(for: $0.canonicalItemName) == key }) {
                modelContext.delete(existing)
            }
        }
    }

    // MARK: - Quick add from history

    private var historicalItemsSorted: [HistoricalGroceryItem] {
        historicalItems.sorted { $0.name < $1.name }
    }

    /// Always shown, even empty — this used to disappear entirely until
    /// something populated it, which made it hard to find in the first
    /// place (there was nothing on screen pointing to it). It fills in on
    /// its own as you check items off (see `GroceryItemRow.recordAsHistorical`),
    /// or instantly via "Paste an Old List" for a new household with
    /// nothing checked off yet. A single flat, alphabetical list — this
    /// used to also break itself down into a dropdown per category
    /// (Produce, Dairy, ...), which was a dropdown-within-a-dropdown for no
    /// real benefit given how short this list usually is. Uses the same row
    /// as "Suggestions From Your Meal Plan" above, by design — feedback was
    /// that the two lists should look alike.
    @ViewBuilder
    private var pastGroceriesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $pastGroceriesExpanded) {
                if historicalItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing here yet.")
                            .foregroundStyle(.secondary)
                        Button {
                            showHistoryImport = true
                        } label: {
                            Label("Paste an Old Grocery List", systemImage: "doc.text")
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button("Add All", action: addAllHistorical)
                        .font(.brandCallout.bold())
                        .foregroundStyle(Color.brandForest)
                    ForEach(historicalItemsSorted) { historyItem in
                        GrocerySuggestionRow(
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
                majorHeader("From Your Past Groceries")
            }
        } footer: {
            Text("This fills in automatically as you check items off below — or tap + (or Add All) to bring items from here straight onto your list.")
        }
    }

    private func addAllHistorical() {
        for historyItem in historicalItems where !alreadyInList(historyItem) {
            quickAdd(historyItem)
        }
    }

    private func alreadyInList(_ historyItem: HistoricalGroceryItem) -> Bool {
        let key = GroceryListBuilder.canonicalKey(for: historyItem.name)
        return items.contains { GroceryListBuilder.canonicalKey(for: $0.name) == key }
    }

    private func quickAdd(_ historyItem: HistoricalGroceryItem) {
        guard !alreadyInList(historyItem) else { return }
        let maxIndex = purchasableItems.filter { $0.category == historyItem.category }.map(\.orderIndex).max() ?? 0
        let item = GroceryItem(
            name: historyItem.name,
            category: historyItem.category,
            section: .thisWeek,
            isManuallyAdded: true,
            orderIndex: maxIndex + 1
        )
        modelContext.insert(item)
    }

    // MARK: - Shared

    private func row(for item: GroceryItem) -> some View {
        GroceryItemRow(
            item: item,
            productOption: productOption(for: item),
            onTapProduct: { productPickerItem = item }
        )
    }

    private func productOption(for item: GroceryItem) -> ProductOption? {
        guard let id = item.selectedProductOptionID else { return nil }
        return allProductOptions.first { $0.id == id }
    }

    /// A pronounced top-level heading — "Grocery List", "Suggestions From
    /// Your Meal Plan", "From Your Past Groceries" — standing well out from
    /// the smaller, plain per-category headers (like "Produce") nested
    /// underneath them. `.textCase(nil)` stops List's default
    /// small-caps-gray section-header styling from overriding this.
    private func majorHeader(_ title: String) -> some View {
        Text(title)
            .font(.brandTitle3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, 4)
    }

    /// The page's own title, bigger and centered — more pronounced than
    /// even `majorHeader` above it, since this is the one heading for the
    /// whole screen rather than one of several sections on it.
    private var groceryListTitleHeader: some View {
        Text("Grocery List")
            .font(.brandLargeTitle)
            .foregroundStyle(Color.brandForest)
            .frame(maxWidth: .infinity, alignment: .center)
            .textCase(nil)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// One row shared by "Suggestions From Your Meal Plan" and "From Your Past
/// Groceries" — the same layout and iconography in both places by design
/// (feedback was that the two lists should look alike), just with the
/// Reject button present only where rejecting is actually a thing (a
/// pending suggestion) and absent where it isn't (a past-groceries catalog
/// entry, which is just add-or-already-added).
private struct GrocerySuggestionRow: View {
    let name: String
    let quantityText: String?
    /// Grays the name/quantity out — used for an already-rejected
    /// suggestion (still tappable to add after all) or a past-groceries
    /// item already on the list.
    let isSecondary: Bool
    /// True only when tapping Add genuinely has nothing left to do (a
    /// past-groceries item already on the list) — a rejected suggestion is
    /// still `isSecondary` but stays tappable, since Add is how you
    /// reverse a reject.
    let addIsDisabled: Bool
    let onAdd: () -> Void
    /// `nil` hides the Reject button entirely.
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

private struct GroceryItemRow: View {
    @Bindable var item: GroceryItem
    let productOption: ProductOption?
    let onTapProduct: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var historicalItems: [HistoricalGroceryItem]

    var body: some View {
        HStack {
            Button {
                setChecked(!item.isChecked)
            } label: {
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

            QuantityStepper(count: $item.quantityCount, onDeleteAtMinimum: deleteItem)

            Button(action: onTapProduct) {
                if let productOption {
                    ProductThumbnail(option: productOption)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        // A second, explicitly-worded way to do the same thing the leading
        // circle already does — "already have this at home" and "picked
        // this up in the store" both just mean "I don't need to buy it",
        // so both reuse `isChecked` rather than adding a second flag that
        // would need its own display treatment everywhere.
        .swipeActions(edge: .leading) {
            if !item.isChecked {
                Button {
                    setChecked(true)
                } label: {
                    Label("I Have It", systemImage: "checkmark")
                }
                .tint(.brandForest)
            }
        }
    }

    private func setChecked(_ checked: Bool) {
        item.isChecked = checked
        guard checked else { return }
        recordAsHistorical()
    }

    private func deleteItem() {
        modelContext.delete(item)
    }

    /// Learns from what you actually buy: checking an item off adds it to
    /// the "past groceries" catalog if it isn't already there, so that
    /// catalog builds itself from real shopping trips instead of only ever
    /// growing when someone pastes an old list by hand.
    private func recordAsHistorical() {
        let key = GroceryListBuilder.canonicalKey(for: item.name)
        let alreadyKnown = historicalItems.contains { GroceryListBuilder.canonicalKey(for: $0.name) == key }
        guard !alreadyKnown else { return }
        modelContext.insert(HistoricalGroceryItem(name: item.name, category: item.category))
    }
}

/// A `[-] N [+]` control for `GroceryItem.quantityCount` — how many of an
/// item to get, kept separate from `quantityText` (a free-text description
/// like "3 cups" pulled from a recipe, not necessarily a whole-item count).
/// At 1, the "-" becomes a trash icon: tapping it removes the item from the
/// list entirely instead of getting stuck disabled at a floor of 1.
private struct QuantityStepper: View {
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

struct ProductThumbnail: View {
    let option: ProductOption
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let data = option.photoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if let assetName = option.photoAssetName, UIImage(named: assetName) != nil {
                Image(assetName).resizable().scaledToFill()
            } else {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
