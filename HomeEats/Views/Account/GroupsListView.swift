import SwiftUI

/// Every group the caller belongs to — fetched live from `GET /groups`,
/// same "no local model, backend is the sole source of truth" reasoning as
/// `FriendsListView` (see its own doc comment).
struct GroupsListView: View {
    @State private var groups: [GroupSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateGroup = false
    /// Set the moment `CreateGroupView` actually creates a group, and read
    /// by `.navigationDestination(item:)` below to push straight into it —
    /// landing back on this plain list after creating a group, with the
    /// group you just made now one tap further away than "Invite" needs to
    /// be, was confusing enough on its own to be worth fixing regardless of
    /// anything else.
    @State private var newlyCreatedGroup: GroupDetail?

    var body: some View {
        List {
            if isLoading && groups.isEmpty {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Groups Yet",
                    systemImage: "person.3",
                    description: Text("Create a group to share recipes with a household, or a whole trip's worth of friends, all at once.")
                )
            } else {
                ForEach(groups) { group in
                    NavigationLink(group.name) {
                        GroupDetailView(groupID: group.id, groupName: group.name)
                    }
                }
            }
        }
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateGroup = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showCreateGroup, onDismiss: { Task { await load() } }) {
            CreateGroupView(onCreated: { newlyCreatedGroup = $0 })
        }
        .navigationDestination(item: $newlyCreatedGroup) { group in
            GroupDetailView(groupID: group.id, groupName: group.name)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            groups = try await AccountsAPIClient.getGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "Name a group, pick members from your accepted friends" — its own view
/// (used from the `.sheet` above, mirroring how `RecipePickerSheet`/
/// `RestaurantPickerSheet` are each a dedicated picker rather than an inline
/// list) since it needs its own friends fetch and multi-select state.
///
/// Internal, not `private`, on purpose: the app-creation pivot's
/// `CreateOrJoinFirstGroupView` (a signed-in user's very first stop when
/// they have zero groups) reuses this exact same form rather than
/// duplicating it — a brand-new user creating their very first group is the
/// same task as an existing user creating an additional one, just reached
/// from a different screen. No behavior here changed for that reuse; only
/// the access level did.
struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    /// Called with the group `create()` just made, right before dismissing
    /// — lets `GroupsListView` push straight into it instead of landing
    /// back on the plain group list.
    let onCreated: (GroupDetail) -> Void

    @State private var name = ""
    @State private var friends: [PublicUser] = []
    @State private var selectedFriendIDs: Set<String> = []
    @State private var isLoadingFriends = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Household, Peru Trip", text: $name)
                }
                Section {
                    if isLoadingFriends {
                        ProgressView()
                    } else if friends.isEmpty {
                        // Not a dead end — just create the group now (no
                        // members needed to do that) and invite by phone
                        // number from the group's own page next, which
                        // works for anyone, friend or not. Explaining that
                        // right here (rather than just "add friends first")
                        // is what was actually missing before.
                        Text("You don't have any accepted friends yet to pick from here — that's fine, create the group now and invite anyone by phone number from its page next.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(friends) { friend in
                            friendToggleRow(friend)
                        }
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("You're always included — pick anyone else to add right away, or invite people later from the group's page.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(!canCreate)
                    }
                }
            }
            .task { await loadFriends() }
        }
    }

    private func friendToggleRow(_ friend: PublicUser) -> some View {
        Button {
            if selectedFriendIDs.contains(friend.id) {
                selectedFriendIDs.remove(friend.id)
            } else {
                selectedFriendIDs.insert(friend.id)
            }
        } label: {
            HStack {
                Text(friend.displayNameOrPhoneNumber).foregroundStyle(.primary)
                Spacer()
                if selectedFriendIDs.contains(friend.id) {
                    Image(systemName: "checkmark").foregroundStyle(Color.brandForest)
                }
            }
        }
    }

    private func loadFriends() async {
        isLoadingFriends = true
        defer { isLoadingFriends = false }
        friends = (try? await AccountsAPIClient.getFriends())?.friends ?? []
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let created = try await AccountsAPIClient.createGroup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                memberUserIDs: Array(selectedFriendIDs)
            )
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
