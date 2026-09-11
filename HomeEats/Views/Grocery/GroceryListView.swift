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

    private var calendar: Calendar { Calendar.current }
    private var weekStart: Date {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return calendar.startOfWeek(containing: base)
    }

    private var items: [GroceryItem] {
        allGroceryItems.filter { $0.weekStartDate.isSameDay(as: weekStart) }
    }

    private var thisWeekByCategory: [(GroceryCategory, [GroceryItem])] {
        grouped(items.filter { $0.section == .thisWeek })
    }
    private var staplesByCategory: [(GroceryCategory, [GroceryItem])] {
        grouped(items.filter { $0.section == .staples })
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
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
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

            suggestedSection

            if viewMode == .byCategory {
                byCategorySections
            } else {
                myLayoutSections
            }

            rejectedSection

            quickAddFromHistorySection
        }
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

    @ViewBuilder
    private var suggestedSection: some View {
        if !suggestedItems.isEmpty {
            Section {
                ForEach(suggestedItems) { item in
                    SuggestedItemRow(
                        item: item,
                        onAdd: { accept(item) },
                        onReject: { reject(item) }
                    )
                }
            } header: {
                HStack {
                    Text("Suggested From This Week's Recipes")
                    Spacer()
                    Button("Add All", action: acceptAllSuggested)
                        .font(.brandCaption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandForest)
                }
            } footer: {
                Text("Pulled from this week's planned recipes. Add what you actually need to buy, or reject anything you already have on hand — rejected items move to the Rejected section below.")
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

    // MARK: - Rejected

    @ViewBuilder
    private var rejectedSection: some View {
        if !rejectedItems.isEmpty {
            Section {
                ForEach(rejectedItems) { item in
                    HStack {
                        Text(item.name)
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
            } header: {
                Text("Rejected")
            } footer: {
                Text("Items you said you already have on hand. Tap Add if you change your mind.")
            }
        }
    }

    // MARK: - By category (default) view

    @ViewBuilder
    private var byCategorySections: some View {
        if !thisWeekByCategory.isEmpty {
            ForEach(thisWeekByCategory, id: \.0) { category, categoryItems in
                Section(category.displayName) {
                    ForEach(categoryItems) { item in
                        row(for: item).onDrag { NSItemProvider(object: item.name as NSString) }
                    }
                    .onDelete { offsets in delete(categoryItems, at: offsets) }
                }
                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                    handleCategoryDrop(providers, assigningTo: category)
                }
            }
        } else {
            Section {
                Text("No recipes are planned for this week yet, so there's nothing to shop for. Head to the Plan tab to pick some meals.")
                    .foregroundStyle(.secondary)
            }
        }

        if !staplesByCategory.isEmpty {
            Section {
                ForEach(staplesByCategory, id: \.0) { category, categoryItems in
                    DisclosureGroup(category.displayName) {
                        ForEach(categoryItems) { item in
                            row(for: item).onDrag { NSItemProvider(object: item.name as NSString) }
                        }
                    }
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        handleCategoryDrop(providers, assigningTo: category)
                    }
                }
            } header: {
                Text("Staples")
            } footer: {
                Text("Your household's regular items. Manage the full list from the toolbar. Drag any item onto a different category header to move it there for good.")
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
        guard let match = items.first(where: { GroceryListBuilder.canonicalKey(for: $0.name) == key }) else { return }
        match.category = category
        match.categoryManuallySet = true
    }

    // MARK: - "My Grocery Layout" view

    @ViewBuilder
    private var myLayoutSections: some View {
        let unassigned = items.filter { aisleID(for: $0) == nil }

        Section {
            if unassigned.isEmpty {
                Text("Everything's sorted into an aisle.").foregroundStyle(.secondary)
            }
            ForEach(unassigned) { item in
                row(for: item).onDrag { NSItemProvider(object: item.name as NSString) }
            }
        } header: {
            Text("Unsorted")
        } footer: {
            Text(aisles.isEmpty
                 ? "Add your store's aisles from the toolbar, then drag items onto them."
                 : "Drag an item onto an aisle below to place it there for good.")
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            handleDrop(providers, assigningTo: nil)
        }

        ForEach(aisles) { aisle in
            let aisleItems = items.filter { aisleID(for: $0) == aisle.id }
            Section(aisle.name) {
                if aisleItems.isEmpty {
                    Text("Drop items here").font(.brandCaption).foregroundStyle(.tertiary)
                }
                ForEach(aisleItems) { item in
                    row(for: item).onDrag { NSItemProvider(object: item.name as NSString) }
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

    /// Always shown, even empty — this used to disappear entirely until
    /// something populated it, which made it hard to find in the first
    /// place (there was nothing on screen pointing to it). It fills in on
    /// its own as you check items off (see `GroceryItemRow.recordAsHistorical`),
    /// or instantly via "Paste an Old List" for a new household with
    /// nothing checked off yet.
    @ViewBuilder
    private var quickAddFromHistorySection: some View {
        Section {
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
                ForEach(historicalCategoriesGrouped) { group in
                    DisclosureGroup(group.category.displayName) {
                        ForEach(group.items) { historyItem in
                            HistoryQuickAddRow(
                                name: historyItem.name,
                                isInList: alreadyInList(historyItem),
                                onAdd: { quickAdd(historyItem) }
                            )
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("From Your Past Groceries")
                Spacer()
                if !historicalItems.isEmpty {
                    Button("Add All", action: addAllHistorical)
                        .font(.brandCaption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandForest)
                }
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

    /// A small `Identifiable` wrapper around the grouping result, rather than
    /// a raw `(GroceryCategory, [HistoricalGroceryItem])` tuple — `ForEach`
    /// over a tuple array (`id: \.0`) nested this deeply (Section > ForEach >
    /// DisclosureGroup > ForEach) is a known SwiftUI type-checker trap: it
    /// can fail with misleading "generic parameter could not be inferred" /
    /// "expected argument type Binding<...>" errors that have nothing to do
    /// with the actual code. A named, `Identifiable` element sidesteps it.
    private struct HistoricalCategoryGroup: Identifiable {
        let category: GroceryCategory
        let items: [HistoricalGroceryItem]
        var id: String { category.rawValue }
    }

    private var historicalCategoriesGrouped: [HistoricalCategoryGroup] {
        Dictionary(grouping: historicalItems, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { HistoricalCategoryGroup(category: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
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

    private func delete(_ items: [GroceryItem], at offsets: IndexSet) {
        for index in offsets { modelContext.delete(items[index]) }
    }
}

/// One row of `quickAddFromHistorySection`, pulled out to its own `View`
/// rather than inlined — see the comment on `HistoricalCategoryGroup` above.
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
            Text(name)
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
                Text(item.name)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            QuantityStepper(count: $item.quantityCount)

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
/// Floors at 1 rather than letting the count reach 0, since "0 of an item on
/// your list" isn't meaningfully different from the item not being on the
/// list — removing it entirely is what the swipe-to-delete/checkbox already do.
private struct QuantityStepper: View {
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Button {
                count = max(1, count - 1)
            } label: {
                Image(systemName: "minus.circle")
            }
            .disabled(count <= 1)

            Text("\(count)")
                .font(.brandCaption)
                .monospacedDigit()
                .frame(minWidth: 16)

            Button {
                count += 1
            } label: {
                Image(systemName: "plus.circle")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.brandForest)
    }
}

/// One row of `suggestedSection` — an ingredient pulled from this week's
/// recipes, not yet decided on. Shows Add/Reject instead of the usual
/// checkbox/quantity controls, since it isn't actually "on the list" yet.
private struct SuggestedItemRow: View {
    let item: GroceryItem
    let onAdd: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
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
