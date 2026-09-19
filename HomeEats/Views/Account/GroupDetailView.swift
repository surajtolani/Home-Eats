import SwiftUI

/// One group's member list, with invite/leave/remove actions — fetched live
/// from `GET /groups/:groupId` (see `GroupsListView`'s doc comment on why
/// groups have no local model at all).
///
/// **Phase 5 additions**: `memberRow`'s `.contextMenu` lets a `MANAGER`
/// promote a `PARTICIPANT` or demote a fellow `MANAGER` (see
/// `roleChangeMenuItems`'s own doc comment for exactly who sees which
/// action), and a "Pending Invites" section (visible to a `MANAGER` only,
/// via the new `GET /groups/:groupId/invites` — see `GroupSentInvite`'s own
/// doc comment in AccountModels.swift for why that endpoint isn't part of
/// Phase 5 itself) lists this group's own outstanding `PENDING`/`DECLINED`
/// invites, with a "Resend" action on a declined one.
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
    /// Backs the rename `.alert` below — direct user request: "Group names
    /// should be editable by the managers," which this screen had no way
    /// to do at all before (a group's name could only ever be set once, at
    /// creation, via `CreateGroupView`).
    @State private var showRenameAlert = false
    @State private var renameText = ""
    /// Backs the default-location `.alert` below — direct user request:
    /// "each 'group' should have an option to select a location - so if a
    /// group is created for a trip, then you know what the default
    /// location is," so "Ask for a Restaurant" defaults to the trip's
    /// destination instead of wherever the person asking physically is.
    /// See `GroupDetail.defaultLocationText`'s own doc comment.
    @State private var showLocationAlert = false
    @State private var locationText = ""
    /// This group's own outstanding invites (`PENDING`/`DECLINED` only —
    /// see `GroupSentInvite`'s own doc comment), for the "Pending Invites"
    /// section below. Loaded alongside `group` in `load()`, only when
    /// `isManager` (the underlying `GET /groups/:groupId/invites` is
    /// `MANAGER`-only server-side too — see that route's own doc comment in
    /// routes/groups.js). Left empty rather than blanking the whole screen
    /// if this one fetch fails (see `load()`'s own `try?`) — this is
    /// secondary information a `GroupDetailView` visit has always worked
    /// fine without until now.
    @State private var sentInvites: [GroupSentInvite] = []
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
                    // A trip group's destination — "Ask for a Restaurant"
                    // defaults here when no location is named in the
                    // search itself, instead of wherever the person
                    // asking's own device currently is. MANAGER-editable
                    // only (server-enforced too — see `updateLocation()`'s
                    // own doc comment), but shown to every member so a
                    // PARTICIPANT can see what it's set to.
                    Button {
                        locationText = group.defaultLocationText ?? ""
                        showLocationAlert = true
                    } label: {
                        HStack {
                            Label("Default Location", systemImage: "mappin.and.ellipse")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(group.defaultLocationText ?? "Not Set")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!isManager)
                }
                Section("Members") {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                }
                // Not part of Phase 5 itself — see `GroupSentInvite`'s own
                // doc comment in AccountModels.swift and
                // `getGroupInvites`'s own doc comment for why this endpoint
                // exists at all. Hidden entirely (not just an empty-state
                // message) when there's nothing outstanding, same as every
                // other conditionally-shown section on this screen.
                if isManager && !sentInvites.isEmpty {
                    Section("Pending Invites") {
                        ForEach(sentInvites) { invite in
                            pendingInviteRow(invite)
                        }
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
                // Renaming is a management action, same MANAGER gate as
                // inviting/promoting/demoting — see this screen's own
                // `isManager` doc comment and routes/groups.js's `PATCH
                // /:groupId` doc comment for why.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        renameText = group?.name ?? groupName
                        showRenameAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Rename Group")
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
        .alert("Rename Group", isPresented: $showRenameAlert) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("Default Location", isPresented: $showLocationAlert) {
            TextField("e.g. BGC, Manila, Philippines", text: $locationText)
            Button("Cancel", role: .cancel) {}
            // Empty is a valid save here, unlike renaming — it clears the
            // default back to "no default, use whoever's asking's own
            // current location."
            Button("Save") { Task { await updateLocation() } }
        } message: {
            Text("Used as the default for \"Ask for a Restaurant\" when no location is named in the search — handy for a trip.")
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

    // Name only, no phone-number subtitle — same "identify people by who
    // they are, not the number tied to their account" reasoning as
    // `FriendsListView.friendRow`; see its own doc comment.
    //
    // **Promote/demote (Phase 5)**: direct user request replaced a
    // standalone "..." menu button next to "Remove" with the role title
    // itself, shown right next to the member's name — tapping IT opens the
    // promote/demote menu, rather than a separate icon elsewhere in the
    // row. `roleBadge(for:)` below is now always shown (every member has a
    // role worth labeling, not just a Manager) and becomes the `Menu`'s
    // own label for a MANAGER looking at someone other than themselves —
    // same `roleChangeMenuItems(for:)` content the old ellipsis button
    // used to open. `.contextMenu` stays too as a bonus for anyone who
    // already knows to long-press, same "not redundant, different habits"
    // reasoning that row's swipe actions and an always-visible tappable
    // control already coexist for elsewhere in this app (see
    // `GroupSharedGroceryListView`'s "Move to Aisle" menu doc comment).
    private func memberRow(_ member: GroupMember) -> some View {
        let isSelf = member.id == accountSession.currentUser?.id
        return HStack {
            HStack(spacing: 6) {
                Text(member.displayNameOrPhoneNumber)
                if isManager && !isSelf {
                    Menu {
                        roleChangeMenuItems(for: member)
                    } label: {
                        roleBadge(for: member)
                    }
                    .buttonStyle(.plain)
                } else {
                    roleBadge(for: member)
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
        .contextMenu {
            roleChangeMenuItems(for: member)
        }
    }

    /// "Manager"/"Member" capsule — Phase 3's role, surfaced here so it's
    /// visible without a separate screen (matches `GET /groups/:groupId`
    /// including `role` per member — see backend/README.md's "Group
    /// roles" section). Always shown now (used to be Manager-only, with a
    /// Participant getting no badge at all) — direct user request, since
    /// this is also now the tappable target `memberRow` wraps in a `Menu`
    /// for a MANAGER viewing someone else; a small chevron hints that it's
    /// interactive in that case. "Member," not the backend's own
    /// "Participant," to match how the user themselves refers to the role.
    private func roleBadge(for member: GroupMember) -> some View {
        let isSelf = member.id == accountSession.currentUser?.id
        return HStack(spacing: 2) {
            Text(member.role == .manager ? "Manager" : "Member")
            if isManager && !isSelf {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
        }
        .font(.brandCaption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(member.role == .manager ? Color.brandForest.opacity(0.15) : Color.secondary.opacity(0.12))
        )
        .foregroundStyle(member.role == .manager ? Color.brandForest : Color.secondary)
    }

    /// A `MANAGER` viewing a `PARTICIPANT` (never themselves — you can't
    /// promote yourself, there'd be nobody to grant it) gets "Promote to
    /// Manager"; a `MANAGER` viewing a fellow `MANAGER` OTHER than
    /// themselves gets "Demote to Participant" (per this task's own spec —
    /// self-demote already exists, just spelled "Leave" above, since
    /// demoting yourself while remaining a member isn't a scenario this UI
    /// separately exposes). `@ViewBuilder` rather than returning `some View`
    /// directly — the `if`/`else` below produces genuinely different view
    /// types (`Button` vs. `EmptyView`), which a single non-`@ViewBuilder`
    /// return type can't express without an `AnyView` erase.
    @ViewBuilder
    private func roleChangeMenuItems(for member: GroupMember) -> some View {
        let isSelf = member.id == accountSession.currentUser?.id
        if isManager && !isSelf {
            if member.role == .participant {
                Button {
                    Task { await promote(member.id) }
                } label: {
                    Label("Promote to Manager", systemImage: "arrow.up.circle")
                }
            } else {
                Button {
                    Task { await demote(member.id) }
                } label: {
                    Label("Demote to Participant", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    /// A group's own outstanding invite — who was invited, by whom, and
    /// (for a `DECLINED` one) a "Resend" action. See `GroupSentInvite`'s own
    /// doc comment for the exact shape and `resendInvite(_:)` below for why
    /// "Resend" is just calling `POST /groups/:groupId/invite` again.
    private func pendingInviteRow(_ invite: GroupSentInvite) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.displayLabel)
                Text("Invited by \(invite.invitedBy.displayNameOrPhoneNumber)")
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch invite.status {
            case .pending:
                Text("Pending")
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
            case .declined:
                Button("Resend") {
                    Task { await resendInvite(invite) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            let fetched = try await AccountsAPIClient.getGroup(id: groupID)
            group = fetched
            // `MANAGER`-only server-side (see `getGroupInvites`'s own doc
            // comment) — computed from `fetched` directly rather than
            // `isManager` (which reads `group`, not yet updated to
            // `fetched` at this point in the method) to avoid gating on a
            // stale role from before this very load. `try?`, not `try`: a
            // failed invites fetch is secondary information that shouldn't
            // blank the rest of an otherwise-successful group load — see
            // `sentInvites`'s own doc comment.
            if fetched.myRole(currentUserID: accountSession.currentUser?.id) == .manager {
                sentInvites = (try? await AccountsAPIClient.getGroupInvites(groupID: groupID)) ?? []
            } else {
                sentInvites = []
            }
        } catch {
            if isFirstLoad {
                errorMessage = error.localizedDescription
            } else {
                actionFailure = error.localizedDescription
            }
        }
    }

    /// `MANAGER`-only server-side (`PATCH /groups/:groupId` — see that
    /// route's own doc comment) — the toolbar button that opens
    /// `showRenameAlert` is already hidden from anyone else, but this
    /// doesn't re-check `isManager` itself since a 403 here surfaces
    /// cleanly through `actionFailure` regardless, same as every other
    /// action on this screen.
    private func rename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            group = try await AccountsAPIClient.renameGroup(groupID: groupID, name: trimmed)
        } catch {
            actionFailure = error.localizedDescription
        }
    }

    /// `MANAGER`-only server-side, same as `rename()` above (both go
    /// through `PATCH /groups/:groupId` — see that route's own doc
    /// comment). Unlike `rename()`, an empty result is a valid save here:
    /// it clears the group back to "no default location."
    private func updateLocation() async {
        let trimmed = locationText.trimmingCharacters(in: .whitespaces)
        do {
            group = try await AccountsAPIClient.updateGroupLocation(
                groupID: groupID,
                locationText: trimmed.isEmpty ? nil : trimmed
            )
        } catch {
            actionFailure = error.localizedDescription
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

    private func promote(_ userID: String) async {
        do {
            _ = try await AccountsAPIClient.promoteMember(groupID: groupID, userID: userID)
            await load()
        } catch {
            actionFailure = error.localizedDescription
        }
    }

    /// A `409` here (the last-manager guard — see `demoteMember`'s own doc
    /// comment) surfaces through `actionFailure`'s existing alert exactly
    /// like any other failure this screen already handles that way, rather
    /// than silently doing nothing — same "surface it clearly" requirement
    /// this task's own spec calls out for this specific case.
    private func demote(_ userID: String) async {
        do {
            _ = try await AccountsAPIClient.demoteMember(groupID: groupID, userID: userID)
            await load()
        } catch {
            actionFailure = error.localizedDescription
        }
    }

    /// "Resend" for a `DECLINED` invite is just calling
    /// `POST /groups/:groupId/invite` again with the same phone number —
    /// see `inviteToGroup(groupID:phoneNumber:)`'s own "Resend after a
    /// decline" doc comment. Always the `phoneNumber:` overload, never
    /// `userID:`, regardless of whether `invite.invitedUser` is now set —
    /// the phone-number path accepts any target (friend, non-friend, or
    /// stranger) unconditionally, so it's the one overload guaranteed to
    /// work here no matter how the original invite was created or whether
    /// the caller and the invited person are (still, or now) friends.
    private func resendInvite(_ invite: GroupSentInvite) async {
        do {
            try await AccountsAPIClient.inviteToGroup(groupID: groupID, phoneNumber: invite.invitedPhoneNumber)
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
                // Phase 5: tapping a friend here no longer adds them
                // instantly — `inviteToGroup(groupID:userID:)` now queues a
                // PENDING `Invite` the same as the phone-number path below
                // always has (see that method's own doc comment). The
                // footer makes that explicit rather than leaving the
                // pre-Phase-5 impression that a tap here means "now a
                // member."
                Section {
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
                } header: {
                    Text("From Your Friends")
                } footer: {
                    Text("Tapping a friend sends them an invite to this group — they'll join once they accept, same as anyone invited by phone number below.")
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
