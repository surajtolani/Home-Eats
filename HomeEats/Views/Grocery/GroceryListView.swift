import SwiftUI
import SwiftData
import UIKit

struct GroceryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayPlan.date) private var allDayPlans: [DayPlan]
    @Query private var staples: [StapleItem]
    @Query private var allProductOptions: [ProductOption]
    @Query private var allGroceryItems: [GroceryItem]

    @State private var weekOffset: Int = 0
    @State private var showStaplesManager = false
    @State private var showAddItemSheet = false
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
                Button {
                    regenerate()
                } label: {
                    Label("Generate List for This Week", systemImage: "arrow.clockwise")
                }
            }

            if !thisWeekByCategory.isEmpty {
                ForEach(thisWeekByCategory, id: \.0) { category, categoryItems in
                    Section(category.displayName) {
                        ForEach(categoryItems) { item in
                            GroceryItemRow(
                                item: item,
                                productOption: productOption(for: item),
                                onTapProduct: { productPickerItem = item }
                            )
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
                                GroceryItemRow(
                                    item: item,
                                    productOption: productOption(for: item),
                                    onTapProduct: { productPickerItem = item }
                                )
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
        .sheet(item: $productPickerItem) { item in
            ProductOptionPickerView(genericItemName: item.name) { chosen in
                item.selectedProductOptionID = chosen?.id
            }
        }
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
