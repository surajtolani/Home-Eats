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

    var body: some View {
        List {
            if isLoading && group == nil {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            } else if let group {
                // Phase 4 — the group's shared, backend-hosted meal plan and
                // grocery list (contrast with everything below, which is
                // just this group's *membership* info): reached from here,
                // not folded into the personal Plan/Grocery tabs, per this
                // feature's own scope (see `GroupSharedMealPlanView`'s doc
                // comment). Shown for every member regardless of role — a
                // `PARTICIPANT` can still suggest/vote/check things off on
                // both, they just don't get every action once inside (see
                // each screen's own role gating).
                Section("Shared With This Group") {
                    NavigationLink {
                        GroupSharedMealPlanView(groupID: groupID, groupName: group.name)
                    } label: {
                        Label("Shared Meal Plan", systemImage: "calendar")
                    }
                    NavigationLink {
                        GroupSharedGroceryListView(groupID: groupID, groupName: group.name)
                    } label: {
                        Label("Shared Grocery List", systemImage: "cart")
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInvite = true
                } label: {
                    Image(systemName: "person.badge.plus")
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
            // for how it reads. Removing someone else is `MANAGER`-only as
            // of Phase 3 (see backend/README.md's "Group roles" section);
            // this button is shown to everyone regardless (pre-existing
            // Phase 2/3 behavior, unchanged by this Phase 4 task, which is
            // scoped to the new shared meal-plan/grocery-list screens
            // above, not to gating group-membership management itself) —
            // a `PARTICIPANT` tapping it on someone else simply gets the
            // backend's `403` back as an inline error, same as any other
            // server-declined request elsewhere in this app.
            Button(member.id == accountSession.currentUser?.id ? "Leave" : "Remove", role: .destructive) {
                Task { await remove(member.id) }
            }
            .buttonStyle(.borderless)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            group = try await AccountsAPIClient.getGroup(id: groupID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ userID: String) async {
        do {
            try await AccountsAPIClient.removeGroupMember(groupID: groupID, userID: userID)
            await load()
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var phoneNumber = ""
    @State private var isInviting = false
    @State private var errorMessage: String?

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
                    TextField("Phone number", text: $phoneNumber)
                        .keyboardType(.phonePad)
                    Button("Invite") { Task { await invite(phoneNumber: phoneNumber) } }
                        .disabled(PhoneNumberFormatting.e164(from: phoneNumber) == nil || isInviting)
                } header: {
                    Text("By Phone Number")
                } footer: {
                    Text("If they're not one of your accepted friends yet (whether or not they're on Home Eats already), this sends a friend request and queues them for this group — they'll join it once they accept.")
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
