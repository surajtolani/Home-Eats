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

    /// Anyone picked via `ContactOrPhoneNumberPickerView` — a contact or a
    /// manually-typed number, not yet an accepted friend (or not even
    /// necessarily a friend candidate the "From Your Friends" list above
    /// could ever offer). The group doesn't exist yet at this point in the
    /// form, so these can't be invited immediately the way
    /// `InviteToGroupView` does — they're just queued here and actually
    /// sent as `inviteToGroup(groupID:phoneNumber:)` calls right after
    /// `create()`'s `POST /groups` succeeds. See `create()`'s own doc
    /// comment for what happens if one of those calls fails.
    @State private var pendingPhoneInvites: [PickedPhoneContact] = []
    @State private var showContactPicker = false
    /// Set once `create()` has actually made the group — from that point
    /// on the form is done (name/members can't meaningfully change
    /// anymore), and the toolbar swaps from "Create" to "Done" rather than
    /// letting a second tap fire a second `POST /groups`.
    @State private var didFinishCreating = false

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating && !didFinishCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Household, Peru Trip", text: $name)
                }
                .disabled(didFinishCreating)
                Section {
                    if isLoadingFriends {
                        ProgressView()
                    } else if friends.isEmpty {
                        // Not a dead end — the "Add by Contact or Phone
                        // Number" row below covers this regardless of
                        // whether there are any accepted friends to pick
                        // from here at all. Explaining that right here
                        // (rather than just "add friends first") is what
                        // was actually missing before.
                        Text("You don't have any accepted friends yet to pick from here — that's fine, add anyone by contact or phone number below instead.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(friends) { friend in
                            friendToggleRow(friend)
                        }
                    }
                    ForEach(pendingPhoneInvites, id: \.phoneNumber) { invite in
                        HStack {
                            Text(invite.displayLabel).foregroundStyle(.primary)
                            Spacer()
                            Text("Will invite").font(.brandCaption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in pendingPhoneInvites.remove(atOffsets: offsets) }
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Add by Contact or Phone Number", systemImage: "person.crop.circle.badge.plus")
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("You're always included. Pick from your accepted friends above, or add anyone else by contact or phone number — they'll get a friend request and join once they accept.")
                }
                .disabled(didFinishCreating)
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !didFinishCreating {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else if didFinishCreating {
                        // The group already exists by the time this shows
                        // (see `create()`) — this just closes the sheet
                        // rather than submitting anything again.
                        Button("Done") { dismiss() }
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(!canCreate)
                    }
                }
            }
            .task { await loadFriends() }
            .sheet(isPresented: $showContactPicker) {
                ContactOrPhoneNumberPickerView { picked in
                    // Dedupe by phone number — picking the same person
                    // twice (once via search, once by re-typing their
                    // number) would otherwise queue two identical
                    // `inviteToGroup` calls in `create()` below.
                    guard !pendingPhoneInvites.contains(where: { $0.phoneNumber == picked.phoneNumber }) else { return }
                    pendingPhoneInvites.append(picked)
                }
            }
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

    /// Creates the group with its accepted-friend members (`memberUserIDs`,
    /// a single atomic `POST /groups`), then — since a group has to exist
    /// before anyone can be invited *to* it — fires off one
    /// `inviteToGroup(groupID:phoneNumber:)` call per queued
    /// `pendingPhoneInvites` entry, in a loop, one request at a time.
    ///
    /// `onCreated(created)` is called right after the group itself is made,
    /// regardless of how the phone invites below go — the group exists and
    /// is real the moment `POST /groups` returns, so `GroupsListView`
    /// pushing into it shouldn't be held hostage by an unrelated invite
    /// failing. If every phone invite succeeds, this sheet then dismisses
    /// itself exactly like before. If one or more fail (a bad number that
    /// still shape-checked, a transient network blip mid-loop, ...), the
    /// sheet stays open instead with the names/numbers that didn't go
    /// through spelled out in `errorMessage` and the toolbar swapped to
    /// "Done" (see `didFinishCreating`) — so nobody quietly loses track of
    /// who actually got invited and who needs a retry from the group's own
    /// "Invite" flow. A partial failure never rolls back or retries
    /// automatically; the group and whichever invites did land stay exactly
    /// as they landed.
    private func create() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let created = try await AccountsAPIClient.createGroup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                memberUserIDs: Array(selectedFriendIDs)
            )
            didFinishCreating = true
            onCreated(created)

            var failedLabels: [String] = []
            for invite in pendingPhoneInvites {
                do {
                    try await AccountsAPIClient.inviteToGroup(groupID: created.id, phoneNumber: invite.phoneNumber)
                } catch {
                    failedLabels.append(invite.displayLabel)
                }
            }

            if failedLabels.isEmpty {
                dismiss()
            } else {
                errorMessage = "\"\(created.name)\" was created, but these invites didn't go through: \(failedLabels.joined(separator: ", ")). You can invite them again from the group's page."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
