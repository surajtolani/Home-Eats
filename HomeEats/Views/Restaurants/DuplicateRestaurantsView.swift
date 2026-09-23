import SwiftUI
import SwiftData

/// "There should be a way to eliminate duplications" (direct user
/// request) — this covers restaurants that ALREADY exist twice, as opposed
/// to `RestaurantEditorView.duplicateMatch`/`RestaurantSearchModel.Result
/// .existingMatch(in:)`, which stop a *new* one from being added going
/// forward. Reachable from `RestaurantListView`'s toolbar.
///
/// Groups every restaurant by a case-insensitive, trimmed name match —
/// same normalization `RestaurantEditorView.duplicateMatch` uses — and
/// shows only groups with more than one entry. Each group can be resolved
/// two ways: "Keep Oldest, Delete Rest" (the common case — a duplicate is
/// almost always the newer, accidental add) as a one-tap bulk action, or
/// manual per-row delete for picking a different one to keep. Deleting
/// here is the exact same operation as `RestaurantListView`'s own
/// swipe-to-delete (`CascadeCleanup.removeReferences` + an immediate
/// backend delete for anything already synced) — not a special
/// "duplicate delete," just this same screen's easier way to reach it for
/// several rows at once.
struct DuplicateRestaurantsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Restaurant.createdAt) private var restaurants: [Restaurant]
    /// Same guard as `RestaurantListView`'s own swipe-to-delete — see
    /// `CascadeCleanup`'s doc comment. A duplicate still decided into a
    /// meal plan isn't safe to blanket-delete via "Keep Oldest, Delete
    /// Rest" either.
    @State private var deleteBlockedMessage: String?
    /// Same fix, same reasoning, as `DuplicateRecipesView`'s own
    /// `groupPendingBulkDelete` — see that type's doc comment.
    @State private var groupPendingBulkDelete: [Restaurant]?

    private var duplicateGroups: [[Restaurant]] {
        let grouped = Dictionary(grouping: restaurants) { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        return grouped.values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.createdAt < $1.createdAt } }
            .sorted { ($0.first?.name ?? "") < ($1.first?.name ?? "") }
    }

    var body: some View {
        NavigationStack {
            List {
                if duplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No Duplicates Found",
                        systemImage: "checkmark.circle",
                        description: Text("Every restaurant in your library has a distinct name.")
                    )
                } else {
                    ForEach(duplicateGroups, id: \.first?.id) { group in
                        Section {
                            ForEach(group) { restaurant in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(restaurant.name)
                                        if let descriptorLine = restaurant.descriptorLine {
                                            Text(descriptorLine)
                                                .font(.brandCaption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let address = restaurant.address, !address.isEmpty {
                                            Text(address)
                                                .font(.brandCaption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if restaurant.id == group.first?.id {
                                        Text("Oldest").font(.brandCaption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets { delete(group[index]) }
                            }
                        } header: {
                            Text("\(group.first?.name ?? "") — \(group.count) copies")
                        } footer: {
                            Button(role: .destructive) {
                                groupPendingBulkDelete = group
                            } label: {
                                Text("Keep Oldest, Delete Rest")
                            }
                            .font(.brandSubheadline)
                        }
                    }
                }
            }
            .navigationTitle("Duplicate Restaurants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Can't Delete Restaurant",
                isPresented: Binding(get: { deleteBlockedMessage != nil }, set: { if !$0 { deleteBlockedMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteBlockedMessage ?? "")
            }
            .confirmationDialog(
                "Delete \(max((groupPendingBulkDelete?.count ?? 1) - 1, 0)) Duplicate Restaurants?",
                isPresented: Binding(get: { groupPendingBulkDelete != nil }, set: { if !$0 { groupPendingBulkDelete = nil } }),
                titleVisibility: .visible,
                presenting: groupPendingBulkDelete
            ) { group in
                Button("Delete", role: .destructive) {
                    for restaurant in group.dropFirst() { delete(restaurant) }
                    groupPendingBulkDelete = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Keeps the oldest copy and deletes the rest. This can't be undone.")
            }
        }
    }

    /// Identical to `RestaurantListView`'s own swipe-to-delete — see that
    /// screen's `.onDelete` for the twin implementation this deliberately
    /// mirrors rather than factors out (small enough, and each call site
    /// reads clearer inline than through a shared free function threading
    /// both a `ModelContext` and a captured restaurant through it).
    private func delete(_ restaurant: Restaurant) {
        guard !CascadeCleanup.isRestaurantInAnyPlannedMeal(restaurantID: restaurant.id, in: modelContext) else {
            deleteBlockedMessage = "\"\(restaurant.name)\" is in your meal plan. Remove it from the plan before deleting it."
            return
        }
        CascadeCleanup.removeReferences(toRestaurantID: restaurant.id, in: modelContext)
        if let backendID = restaurant.backendID {
            Task { try? await AccountsAPIClient.deleteRestaurant(id: backendID) }
        }
        modelContext.delete(restaurant)
    }
}
