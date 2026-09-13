import SwiftUI

/// One group's member list, with invite/leave/remove actions — fetched live
/// from `GET /groups/:groupId` (see `GroupsListView`'s doc comment on why
/// groups have no local model at all).
struct GroupDetailView: View {
    let groupID: String
    /// Shown as the nav title immediately (carried over from the
    /// lightweight `GET /groups` row that led here) while the full detail
    /// call is still in flight, so this screen isn't titleless for that
    /// first moment.
    let groupName: String

    @EnvironmentObject private var accountSession: AccountSession

    @State private var group: GroupDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showInvite = false
    /// A failed Leave/Remove tap, shown as a non-blocking `.alert` — not
    /// through `errorMessage`, which replaces this entire screen's content
    /// (member list, Meal Plan/Grocery List links, everything) the moment
    /// it's set (see the `if/else if` chain in `body`). That's the right
    /// behavior for "the very first load failed, there's nothing to show
    /// yet," but blanking an already-loaded group screen just because one
    /// member-removal tap happened to fail (same bug class fixed in
    /// `FriendsListView`'s `actionFailure` — see its doc comment) would hide
    /// the very screen someone needs to try again from.
    @State private var actionFailure: String?

    /// The signed-in caller's own role in *this* group — same
    /// `group?.myRole(currentUserID:)` convention `GroupSharedMealPlanView`/
    /// `GroupSharedGroceryListView` already use for their own role gating.
    /// `nil` until `group` has loaded, which conservatively hides every
    /// MANAGER-only control below until then rather than briefly showing
    /// them to everyone during that first load.
    private var myRole: GroupRole? { group?.myRole(currentUserID: accountSession.currentUser?.id) }
    private var isManager: Bool { myRole == .manager }

    var body: some View {
        List {
            if isLoading && group == nil {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else if let group {
                // This group's own backend-hosted meal plan and grocery list
                // (contrast with everything below, which is just this
                // group's *membership* info) — the exact same screens the
                // main Plan/Grocery tabs show when this group is the active
                // one (see `GroupScopedPlanTab`/`GroupScopedGroceryTab` in
                // RootView.swift), offered again here as a shortcut so you
                // don't have to switch the active group just to peek at
                // another one's plan. Deliberately *not* labeled "Shared
                // Meal Plan"/"Shared Grocery List" any more — every group's
                // plan and list belongs to that group alone (each is its own
                // row in the backend, keyed by groupId); "shared" read as if
                // there were one plan shared across all your groups, which
                // is exactly backwards. Shown for every member regardless of
                // role — a `PARTICIPANT` can still suggest/vote/check things
                // off on both, they just don't get every action once inside
                // (see each screen's own role gating).
                Section(group.name) {
                    NavigationLink {
                        GroupSharedMealPlanView(groupID: groupID, groupName: group.name)
                    } label: {
                        Label("Meal Plan", systemImage: "calendar")
                    }
                    NavigationLink {
                        GroupSharedGroceryListView(groupID: groupID, groupName: group.name)
                    } label: {
                        Label("Grocery List", systemImage: "cart")
                    }
                }
                Section("Members") {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                }
            }
        }
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Inviting a new member is MANAGER-only server-side (`POST
            // /groups/:groupId/invite` — see routes/groups.js's own doc
            // comment on that route). Gating the button itself, not just
            // catching the resulting 403, so a PARTICIPANT never sees an
            // action they can't actually use in the first place.
            if isManager {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInvite = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await load() } }) {
            InviteToGroupView(
                groupID: groupID,
                existingMemberIDs: Set(group?.members.map(\.id) ?? [])
            )
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { actionFailure != nil },
                set: { isPresented in if !isPresented { actionFailure = nil } }
            ),
            presenting: actionFailure
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func memberRow(_ member: GroupMember) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayNameOrPhoneNumber)
                    // Phase 3's role, surfaced here so it's visible without
                    // a separate screen — matches `GET /groups/:groupId`
                    // now including `role` per member (see
                    // backend/README.md's "Group roles" section).
                    if member.role == .manager {
                        Text("Manager")
                            .font(.brandCaption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.brandForest.opacity(0.15)))
                            .foregroundStyle(Color.brandForest)
                    }
                }
                if member.displayName?.isEmpty == false {
                    Text(member.phoneNumber).font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Same route (`DELETE /groups/:groupId/members/:userId`) either
            // way — "Leave" (removing yourself) and "Remove" (removing
            // someone else) are the same call with a different label purely
            // for how it reads. Leaving is open to everyone regardless of
            // role; removing someone *else* is `MANAGER`-only as of Phase 3
            // (see backend/README.md's "Group roles" section) and gated
            // here to match — a `PARTICIPANT` no longer sees a "Remove" they
            // could never actually use (it used to be shown to everyone and
            // just 403 for a non-manager tapping it on someone else).
            let isSelf = member.id == accountSession.currentUser?.id
            if isSelf {
                Button("Leave", role: .destructive) {
                    Task { await remove(member.id) }
                }
                .buttonStyle(.borderless)
            } else if isManager {
                Button("Remove", role: .destructive) {
                    Task { await remove(member.id) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // Same "first load blanks the screen, a later refresh doesn't"
        // split as `FriendsListView.load()` — this is also called from
        // `.refreshable` and from the invite sheet's `onDismiss`, either of
        // which can run after `group` is already on screen.
        let isFirstLoad = group == nil
        do {
            group = try await AccountsAPIClient.getGroup(id: groupID)
        } catch {
            if isFirstLoad {
                errorMessage = error.localizedDescription
            } else {
                actionFailure = error.localizedDescription
            }
        }
    }

    private func remove(_ userID: String) async {
        do {
            try await AccountsAPIClient.removeGroupMember(groupID: groupID, userID: userID)
            await load()
        } catch {
            actionFailure = error.localizedDescription
        }
    }
}

/// Invite an existing friend (picked from a list) or someone else entirely
/// by phone number — the two paths `POST /groups/:groupId/invite` supports
/// (see backend/README.md's endpoint table).
private struct InviteToGroupView: View {
    let groupID: String
    /// Friends already in the group, filtered out of the "from your
    /// friends" list below — inviting them again would just come back as a
    /// `409` ("already a member"), so there's no reason to offer it as an
    /// option in the first place.
    let existingMemberIDs: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var friends: [PublicUser] = []
    @State private var isLoadingFriends = false
    @State private var isInviting = false
    @State private var errorMessage: String?
    /// Drives `ContactOrPhoneNumberPickerView` — the group already exists
    /// here (unlike `CreateGroupView`'s member step), so a pick from it
    /// goes straight into `invite(phoneNumber:)` below rather than being
    /// queued anywhere.
    @State private var showContactPicker = false

    private var invitableFriends: [PublicUser] {
        friends.filter { !existingMemberIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("From Your Friends") {
                    if isLoadingFriends {
                        ProgressView()
                    } else if invitableFriends.isEmpty {
                        Text("No friends left to invite — everyone you're friends with is already in this group.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(invitableFriends) { friend in
                            Button(friend.displayNameOrPhoneNumber) {
                                Task { await invite(userID: friend.id) }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Add by Contact or Phone Number", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(isInviting)
                } header: {
                    Text("By Phone Number")
                } footer: {
                    Text("Search your contacts by name, or type a number directly. If they're not one of your accepted friends yet (whether or not they're on Home Eats already), this sends a friend request and queues them for this group — they'll join it once they accept.")
                }
                if isInviting {
                    ProgressView()
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadFriends() }
            .sheet(isPresented: $showContactPicker) {
                ContactOrPhoneNumberPickerView { picked in
                    Task { await invite(phoneNumber: picked.phoneNumber) }
                }
            }
        }
    }

    private func loadFriends() async {
        isLoadingFriends = true
        defer { isLoadingFriends = false }
        friends = (try? await AccountsAPIClient.getFriends())?.friends ?? []
    }

    private func invite(userID: String) async {
        isInviting = true
        errorMessage = nil
        defer { isInviting = false }
        do {
            try await AccountsAPIClient.inviteToGroup(groupID: groupID, userID: userID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func invite(phoneNumber raw: String) async {
        guard let e164 = PhoneNumberFormatting.e164(from: raw) else { return }
        isInviting = true
        errorMessage = nil
        defer { isInviting = false }
        do {
            try await AccountsAPIClient.inviteToGroup(groupID: groupID, phoneNumber: e164)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
