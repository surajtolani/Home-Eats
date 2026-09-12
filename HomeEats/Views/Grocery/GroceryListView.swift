import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

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

    @State private var weekOffset: Int = 0
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

    private var calendar: Calendar { Calendar.current }
    private var weekStart: Date {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return calendar.startOfWeek(containing: base)
    }

    private var items: [GroceryItem] {
        allGroceryItems.filter { $0.weekStartDate.isSameDay(as: weekStart) }
    }

    /// Everything actually "on the list" to buy — accepted recipe
    /// ingredients plus staples — as opposed to `.suggested` (still pending
    /// a decision) or `.rejected` (explicitly not needed). Staples used to
    /// get their own separate "Staples" section, grouped by category same
    /// as everything else — which just duplicated every category header a
    /// second time. Merging them into one set of category groups here means
    /// each category (e.g. "Produce") appears once, with both this week's
    /// recipe items and standing staples in it together.
    private var purchasableItems: [GroceryItem] {
        items.filter { $0.section == .thisWeek || $0.section == .staples }
    }
    private var purchasableByCategory: [(GroceryCategory, [GroceryItem])] {
        grouped(purchasableItems)
    }
    /// Freshly pulled from this week's recipes, awaiting an Add/Reject
    /// decision — see `GroceryListSection.suggested`.
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
                weekNavigator.listRowSeparator(.hidden)
                Picker("View", selection: $viewMode) {
                    ForEach(GroceryViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                Button {
                    regenerate()
                } label: {
                    Label("Generate List for This Week", systemImage: "arrow.clockwise")
                }
            }

            Section {
            } header: {
                majorHeader("Grocery List")
            }

            if viewMode == .byCategory {
                byCategorySections
            } else {
                myLayoutSections
            }

            suggestionsSection

            pastGroceriesSection
        }
        .navigationTitle("Grocery List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
            // Turns on the reorder (☰) handles for `.onMove` within a
            // category — off by default so normal taps (checkbox, quantity
            // stepper, product photo) work as usual the rest of the time.
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
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
            AddGroceryItemSheet(weekStart: weekStart)
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
    }

    // MARK: - Suggested (from this week's recipes, pending Add/Reject)

    /// One collapsible section — not one dropdown per sub-group — covering
    /// both the pending suggestions and anything already rejected out of
    /// them, since both are really the same "review this week's recipe
    /// ingredients" workflow.
    @ViewBuilder
    private var suggestionsSection: some View {
        if !suggestedItems.isEmpty || !rejectedItems.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $suggestionsExpanded) {
                    if !suggestedItems.isEmpty {
                        Button("Add All", action: acceptAllSuggested)
                            .font(.brandCallout.bold())
                            .foregroundStyle(Color.brandForest)
                        ForEach(suggestedItems) { item in
                            SuggestedItemRow(
                                item: item,
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
                            HStack {
                                Text(item.name.titleCasedForDisplay)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    accept(item)
                                } label: {
                                    Label("Add", systemImage: "plus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } label: {
                    majorHeader("Suggestions From This Week's Recipes")
                }
            } footer: {
                Text("Pulled from this week's planned recipes. Add what you actually need to buy, or reject anything you already have on hand — you can always add a rejected item back later.")
            }
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

    // MARK: - By category (default) view

    @ViewBuilder
    private var byCategorySections: some View {
        if !purchasableByCategory.isEmpty {
            ForEach(Array(purchasableByCategory.enumerated()), id: \.element.0) { index, entry in
                let (category, categoryItems) = entry
                Section {
                    ForEach(categoryItems) { item in
                        draggableRow(for: item)
                    }
                    .onMove { offsets, destination in
                        moveWithinCategory(categoryItems, from: offsets, to: destination)
                    }
                } header: {
                    Text(category.displayName)
                } footer: {
                    // Only shown once, under the last category section,
                    // rather than repeated under every one.
                    if index == purchasableByCategory.count - 1 {
                        Text("Drag the ☰ handle onto a different category header to move an item there for good. Tap Edit (top right) to reorder within a category. Manage your standing staples from the toolbar.")
                    }
                }
                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                    // Dropping the ☰ handle anywhere in this section — the
                    // header or a row, it's all the same target — moves
                    // that item into this category, appended at the end.
                    // Fine-tuning exactly where within the category is what
                    // Edit mode's reorder handles (`.onMove` above) are for.
                    handleCategoryDrop(providers, assigningTo: category)
                }
            }
        } else {
            Section {
                Text("Nothing on your list yet. Plan some meals in the Plan tab, or add a staple from the toolbar, then generate the list.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reads the dragged item's name back out of the drop payload and
    /// re-categorizes it — mirrors `handleDrop` above, but mutates the item's
    /// `category` (and flags `categoryManuallySet` so `GroceryListBuilder`
    /// never overwrites it on a future regenerate) instead of a separate
    /// aisle-assignment table, since "By Category" groups directly off
    /// `GroceryItem.category` rather than a table like "My Layout" does.
    private func handleCategoryDrop(_ providers: [NSItemProvider], assigningTo category: GroceryCategory) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let name = reading as? String else { return }
            Task { @MainActor in
                assignCategory(name, to: category)
            }
        }
        return true
    }

    private func assignCategory(_ name: String, to category: GroceryCategory) {
        let key = GroceryListBuilder.canonicalKey(for: name)
        guard let match = purchasableItems.first(where: { GroceryListBuilder.canonicalKey(for: $0.name) == key }) else { return }
        match.category = category
        match.categoryManuallySet = true
        // Dropped with no specific row to target — append to the end of
        // this category rather than leaving whatever order position it
        // happened to have in its old one.
        let highestInCategory = purchasableItems.filter { $0.category == category }.map(\.orderIndex).max() ?? 0
        match.orderIndex = highestInCategory + 1
    }

    /// Reorders items within one category using SwiftUI's own List-editing
    /// mechanism (`.onMove`, active while the toolbar's Edit button is on)
    /// rather than a second custom drag-and-drop scheme layered on top of
    /// the cross-category one — two independent `.onDrop` targets on the
    /// same row/section (one for "reorder here," one for "recategorize
    /// here") raced each other for which handled a given drop, which is
    /// what caused a dragged item to visually move and then snap back:
    /// the section-level handler was winning and re-appending the item to
    /// the end of its *current* category instead of the row-level one
    /// placing it at the intended position. `.onMove` has none of that
    /// ambiguity — there's exactly one handler, driven directly by the
    /// system's own reorder UI.
    private func moveWithinCategory(_ categoryItems: [GroceryItem], from offsets: IndexSet, to destination: Int) {
        var reordered = categoryItems
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, item) in reordered.enumerated() {
            item.orderIndex = Double(index)
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
                draggableRow(for: item)
            }
        } header: {
            Text("Unsorted")
        } footer: {
            Text(aisles.isEmpty
                 ? "Add your store's aisles from the toolbar, then drag the ☰ handle onto them."
                 : "Drag the ☰ handle onto an aisle below to place it there for good.")
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleDrop(providers, assigningTo: nil)
        }

        ForEach(aisles) { aisle in
            let aisleItems = purchasableItems.filter { aisleID(for: $0) == aisle.id }
            Section(aisle.name) {
                if aisleItems.isEmpty {
                    Text("Drop items here").font(.brandCaption).foregroundStyle(.tertiary)
                }
                ForEach(aisleItems) { item in
                    draggableRow(for: item)
                }
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                handleDrop(providers, assigningTo: aisle)
            }
        }
    }

    /// Reads the dragged item's name back out of the drop payload and
    /// (re)assigns its aisle. `NSItemProvider` loading is callback-based and
    /// not guaranteed to land on the main thread, so the actual model
    /// mutation is dispatched back to the main actor.
    private func handleDrop(_ providers: [NSItemProvider], assigningTo aisle: StoreAisle?) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let name = reading as? String else { return }
            Task { @MainActor in
                if let aisle {
                    assign([name], to: aisle)
                } else {
                    unassign([name])
                }
            }
        }
        return true
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
    /// real benefit given how short this list usually is.
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
                        HistoryQuickAddRow(
                            name: historyItem.name,
                            isInList: alreadyInList(historyItem),
                            onAdd: { quickAdd(historyItem) }
                        )
                    }
                }
            } label: {
                majorHeader("From Your Past Groceries")
            }
        } footer: {
            Text("This fills in automatically as you check items off below — or tap + (or Add All) to bring items from here straight onto this week's list.")
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
        let item = GroceryItem(
            name: historyItem.name,
            category: historyItem.category,
            section: .thisWeek,
            weekStartDate: weekStart,
            isManuallyAdded: true
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

    /// `row(for:)` with a dedicated drag handle in front of it. The row
    /// itself is packed with buttons (checkbox, quantity stepper, product
    /// photo) — attaching `.onDrag` to the whole row meant a touch almost
    /// always landed on one of those first, so the drag gesture rarely
    /// actually got a chance to start. Isolating `.onDrag` to just this
    /// small handle (nothing else is under it) is what actually makes
    /// dragging a row work reliably.
    private func draggableRow(for item: GroceryItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: item.name as NSString) }
            row(for: item)
        }
    }

    private var weekNavigator: some View {
        HStack {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
            Spacer()
            VStack {
                Text("Week of").font(.brandCaption).foregroundStyle(.secondary)
                Text(weekStart.formatted(Date.monthDay)).font(.brandHeadline)
            }
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
    }

    private func productOption(for item: GroceryItem) -> ProductOption? {
        guard let id = item.selectedProductOptionID else { return nil }
        return allProductOptions.first { $0.id == id }
    }

    /// A pronounced top-level heading — "Grocery List", "Suggestions From
    /// This Week's Recipes", "From Your Past Groceries" — standing well out
    /// from the smaller, plain per-category headers (like "Produce")
    /// nested underneath them. `.textCase(nil)` stops List's default
    /// small-caps-gray section-header styling from overriding this.
    private func majorHeader(_ title: String) -> some View {
        Text(title)
            .font(.brandTitle3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.vertical, 4)
    }

    private func regenerate() {
        let weekDays = calendar.daysOfWeek(containing: weekStart)
        let mealsThisWeek = allPlannedMeals.filter { meal in
            weekDays.contains { $0.isSameDay(as: meal.date) }
        }
        GroceryListBuilder.regenerate(
            weekStart: weekStart,
            plannedMeals: mealsThisWeek,
            staples: staples,
            in: modelContext
        )
    }
}

/// One row of `pastGroceriesSection`, pulled out to its own `View`.
private struct HistoryQuickAddRow: View {
    let name: String
    let isInList: Bool
    let onAdd: () -> Void

    private var iconName: String {
        isInList ? "checkmark.circle.fill" : "plus.circle"
    }
    private var iconColor: Color {
        isInList ? .brandForest : .accentColor
    }

    var body: some View {
        HStack {
            Text(name.titleCasedForDisplay)
            Spacer()
            Button(action: onAdd) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            .buttonStyle(.plain)
            .disabled(isInList)
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

/// One row of `suggestionsSection` — an ingredient pulled from this week's
/// recipes, not yet decided on. Shows Add/Reject instead of the usual
/// checkbox/quantity controls, since it isn't actually "on the list" yet.
private struct SuggestedItemRow: View {
    let item: GroceryItem
    let onAdd: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.titleCasedForDisplay)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onReject) {
                Label("Reject", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)

            Button(action: onAdd) {
                Label("Add", systemImage: "plus.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brandForest)
        }
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
