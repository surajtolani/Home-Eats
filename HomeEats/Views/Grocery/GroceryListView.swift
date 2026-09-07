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
    @Query(sort: \DayPlan.date) private var allDayPlans: [DayPlan]
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

            if viewMode == .byCategory {
                byCategorySections
            } else {
                myLayoutSections
            }

            quickAddFromHistorySection
        }
        .navigationTitle("Grocery List")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddItemSheet = true
                    } label: {
                        Label("Add Item", systemImage: "plus")
                    }
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

    // MARK: - By category (default) view

    @ViewBuilder
    private var byCategorySections: some View {
        if !thisWeekByCategory.isEmpty {
            ForEach(thisWeekByCategory, id: \.0) { category, categoryItems in
                Section(category.displayName) {
                    ForEach(categoryItems) { item in
                        row(for: item)
                    }
                    .onDelete { offsets in delete(categoryItems, at: offsets) }
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
                            row(for: item)
                        }
                    }
                }
            } header: {
                Text("Staples")
            } footer: {
                Text("Your household's regular items. Manage the full list from the toolbar.")
            }
        }
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
                row(for: item).draggable(item.name)
            }
        } header: {
            Text("Unsorted")
        } footer: {
            Text(aisles.isEmpty
                 ? "Add your store's aisles from the toolbar, then drag items onto them."
                 : "Drag an item onto an aisle below to place it there for good.")
        }
        .dropDestination(for: String.self) { names, _ in unassign(names) }

        ForEach(aisles) { aisle in
            let aisleItems = items.filter { aisleID(for: $0) == aisle.id }
            Section(aisle.name) {
                if aisleItems.isEmpty {
                    Text("Drop items here").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(aisleItems) { item in
                    row(for: item).draggable(item.name)
                }
            }
            .dropDestination(for: String.self) { names, _ in assign(names, to: aisle) }
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

    @ViewBuilder
    private var quickAddFromHistorySection: some View {
        if !historicalItems.isEmpty {
            Section {
                ForEach(historicalCategoriesGrouped, id: \.0) { category, categoryItems in
                    DisclosureGroup(category.displayName) {
                        ForEach(categoryItems) { historyItem in
                            HStack {
                                Text(historyItem.name)
                                Spacer()
                                Button {
                                    quickAdd(historyItem)
                                } label: {
                                    Image(systemName: alreadyInList(historyItem) ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(alreadyInList(historyItem) ? .green : .accentColor)
                                }
                                .buttonStyle(.plain)
                                .disabled(alreadyInList(historyItem))
                            }
                        }
                    }
                }
            } header: {
                Text("From Your Past Groceries")
            } footer: {
                Text("Tap + to add something you've bought before to this week's list. Paste in an old list from the toolbar.")
            }
        }
    }

    private var historicalCategoriesGrouped: [(GroceryCategory, [HistoricalGroceryItem])] {
        Dictionary(grouping: historicalItems, by: \.category)
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
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
                Text("Week of").font(.caption).foregroundStyle(.secondary)
                Text(weekStart.formatted(Date.monthDay)).font(.headline)
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
        let plansThisWeek = weekDays.compactMap { day in
            allDayPlans.first { $0.date.isSameDay(as: day) }
        }
        GroceryListBuilder.regenerate(
            weekStart: weekStart,
            dayPlans: plansThisWeek,
            staples: staples,
            in: modelContext
        )
    }

    private func delete(_ items: [GroceryItem], at offsets: IndexSet) {
        for index in offsets { modelContext.delete(items[index]) }
    }
}

private struct GroceryItemRow: View {
    @Bindable var item: GroceryItem
    let productOption: ProductOption?
    let onTapProduct: () -> Void

    var body: some View {
        HStack {
            Button {
                item.isChecked.toggle()
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                if !item.quantityText.isEmpty {
                    Text(item.quantityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

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
