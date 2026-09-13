import SwiftUI
import SwiftData

/// The group-scoped counterpart of the personal `StaplesManagerView` —
/// manages the group's standing "staples" list, the digital replacement for
/// the notepad on the fridge. Reuses that screen's *visual* language exactly
/// (toggle row, add sheet, swipe-to-delete — no rename UI at all, matching
/// the personal reference precisely) against the new `GroupStapleItem`
/// SwiftData model instead of the local, personal `StapleItem` (untouched
/// per this feature's own scope notes).
///
/// **Any member, not MANAGER-only** — see `GroupStapleItem`'s own doc
/// comment (and routes/groupGroceryStaples.js's) for the full "routine
/// household admin, not a planning decision" reasoning. Toggling `isActive`
/// off means it won't be included next time a grocery list is generated
/// from staples — though, matching both the local app and the backend
/// today, nothing currently generates one that way; see that field's own
/// doc comment.
///
/// **Local-first**: every action writes to the local SwiftData store first
/// and returns instantly, whether online or off; `GroupSyncService` pushes/
/// pulls in the background.
struct GroupStaplesManagerView: View {
    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query private var staples: [GroupStapleItem]

    @State private var showAddSheet = false

    init(groupID: String) {
        self.groupID = groupID
        let gid = groupID
        _staples = Query(filter: #Predicate<GroupStapleItem> { $0.groupID == gid })
    }

    /// Sorted alphabetically, same as the personal
    /// `@Query(sort: \StapleItem.name)` — see `GroupAislesManagerView
    /// .visibleAisles`'s own doc comment for why this is a plain `.sorted`
    /// rather than a `@Query` sort descriptor alongside the `.pendingDelete`
    /// filter.
    private var visibleStaples: [GroupStapleItem] {
        staples.filter { $0.syncState != .pendingDelete }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if visibleStaples.isEmpty {
                    ContentUnavailableView(
                        "No Staples Yet",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Add the regular items this group always needs, like milk or paper towels.")
                    )
                }
                ForEach(visibleStaples) { staple in
                    Toggle(isOn: Binding(
                        get: { staple.isActive },
                        set: { setActive(staple, $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(staple.name)
                            Text(staple.category.displayName)
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { delete(visibleStaples[index]) }
                }
            }
            .navigationTitle("Group Staples")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddGroupStapleSheet(groupID: groupID, currentUserID: accountSession.currentUser?.id)
            }
        }
    }

    private func setActive(_ staple: GroupStapleItem, _ isActive: Bool) {
        staple.isActive = isActive
        if staple.syncState == .synced { staple.syncState = .pendingUpdate }
        try? modelContext.save()
        triggerSync()
    }

    private func delete(_ staple: GroupStapleItem) {
        if staple.isLocalPlaceholderID {
            modelContext.delete(staple)
        } else {
            staple.syncState = .pendingDelete
        }
        try? modelContext.save()
        triggerSync()
    }

    /// Same fire-and-forget-after-each-write reasoning as
    /// `GroupAislesManagerView.triggerSync` — see its own doc comment.
    private func triggerSync() {
        Task { _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext) }
    }
}

private struct AddGroupStapleSheet: View {
    let groupID: String
    let currentUserID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var category: GroceryCategory = .other
    @State private var quantityText = ""
    /// Once the user picks a category themselves, stop overwriting it as
    /// they keep typing the name — same as the personal `AddStapleSheet`.
    @State private var categoryWasChosenManually = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                    .onChange(of: name) { _, newValue in
                        guard !categoryWasChosenManually else { return }
                        category = GroceryCategory.guess(fromIngredientName: newValue)
                    }
                Picker("Category", selection: Binding(
                    get: { category },
                    set: { category = $0; categoryWasChosenManually = true }
                )) {
                    ForEach(GroceryCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(category)
                    }
                }
                TextField("Usual amount (optional)", text: $quantityText)
            }
            .navigationTitle("New Staple")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addStaple() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addStaple() {
        guard let currentUserID else { return }
        let staple = GroupStapleItem(
            id: GroupStapleItem.newLocalPlaceholderID(), groupID: groupID,
            name: name.trimmingCharacters(in: .whitespaces), category: category,
            defaultQuantityText: quantityText.isEmpty ? nil : quantityText,
            addedByUserID: currentUserID, syncState: .pendingCreate
        )
        modelContext.insert(staple)
        try? modelContext.save()
        Task { _ = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext) }
        dismiss()
    }
}
