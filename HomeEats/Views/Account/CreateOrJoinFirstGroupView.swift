import SwiftUI

/// Shown to a signed-in user with zero groups — `RootView`'s replacement
/// for the old `familyMembers.isEmpty -> OnboardingView()` gate, now that a
/// *group*, not a locally-named `FamilyMember`, is what the main Plan/
/// Grocery tabs key off of (see `ActiveGroupSession`'s doc comment for the
/// full reasoning). Getting into at least one group is the only thing the
/// app truly needs before its main tabs are useful, same "getting one real
/// thing set up is the only gate" spirit `OnboardingView`'s own doc comment
/// described for `FamilyMember` — just pointed at the new organizing
/// concept.
///
/// Two genuinely different cold-start paths land here, both handled on this
/// one screen rather than a multi-step wizard:
///
/// 1. **A pending invite is already waiting.** Per the invite-consent
///    design in `backend/routes/friends.js`/`auth.js`, someone can be
///    invited to a group by phone number before they've ever signed up
///    (`GroupDetailView`'s "Invite" sheet explains this: "this sends a
///    friend request and queues them for this group — they'll join it once
///    they accept"). For that person, the very first thing they should see
///    isn't a blank "create a group" form — it's the friend request that's
///    already sitting there, one Accept away from putting them straight
///    into a real group with its own shared plan and list. This screen
///    fetches `AccountsAPIClient.getFriends()` and surfaces
///    `incomingRequests` prominently, reusing `FriendsListView`'s own
///    accept/decline calls (not duplicating that logic — just calling the
///    same `AccountsAPIClient` methods `FriendsListView`'s
///    `respond(to:accept:)` does) rather than routing through that whole
///    screen, which also shows friends/outgoing-requests noise that's
///    irrelevant to "get this person into their first group as fast as
///    possible."
/// 2. **Starting fresh.** Reuses `CreateGroupView` (made internal in
///    `GroupsListView.swift` specifically for this reuse — see its own doc
///    comment) unmodified, in the same `.sheet` pattern `GroupsListView`
///    itself uses.
///
/// Whichever path results in at least one group, this screen doesn't need
/// an explicit "Continue" button to move on: `RootView`'s own gating
/// condition (`activeGroupSession.groups.isEmpty`) naturally swaps this
/// screen out for the main `TabView` the moment `groups` becomes
/// non-empty — the same reactive, state-drives-the-UI pattern already used
/// throughout this app (see `RootView`'s own gating chain) rather than a
/// manually-dismissed screen. Both actions below call
/// `activeGroupSession.refreshGroups()` afterward specifically to make that
/// state change happen.
struct CreateOrJoinFirstGroupView: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession

    @State private var friendsList: FriendsList?
    @State private var isLoadingFriends = false
    @State private var errorMessage: String?
    @State private var showCreateGroup = false
    /// Tracks an in-flight accept/decline so its row can show a spinner
    /// instead of letting a second tap fire a second request against the
    /// same friendship id while the first is still in flight.
    @State private var respondingToID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Join a Group")
                        .font(.brandTitle2.bold())
                    Text("Home Eats plans meals and groceries around a group — a household, a trip, however you split things up. Accept an invite below, or start a new group of your own.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)
                .padding(.horizontal)

                List {
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                            Button("Retry") { Task { await loadFriends() } }
                        }
                    }

                    if isLoadingFriends && friendsList == nil {
                        Section {
                            ProgressView()
                        }
                    } else if let incoming = friendsList?.incomingRequests, !incoming.isEmpty {
                        Section {
                            ForEach(incoming) { request in
                                incomingRequestRow(request)
                            }
                        } header: {
                            Text("Waiting For You")
                        } footer: {
                            // No longer an unconditional claim about every
                            // row in this section — direct fix for a real
                            // gap: a friend request sent as part of a
                            // group invite and a plain "be my friend"
                            // request look identical here, but only the
                            // former actually adds you to a group on
                            // accept. Each row now says so itself
                            // (`incomingRequestRow`'s own caption) when
                            // true; this footer just explains what that
                            // per-row label means.
                            Text("A request that names a group adds you to it right away when accepted.")
                        }
                    }

                    Section {
                        Button {
                            showCreateGroup = true
                        } label: {
                            Label("Create a New Group", systemImage: "plus.circle")
                        }
                    } footer: {
                        Text("Name it, optionally add friends now — you can always invite more people from the group's page later.")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color.brandCream.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadFriends() }
            .refreshable { await loadFriends() }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView(onCreated: { created in
                    // Reconcile `activeGroupSession` against the server
                    // first (it needs the fresh list regardless), then
                    // explicitly point `activeGroupID` at the group just
                    // created — otherwise, if an invite from the section
                    // above happened to resolve into a *different* group in
                    // the same moment (unlikely, but not impossible on a
                    // slow connection), `refreshGroups()`'s own "first
                    // group in the list" fallback could land on that one
                    // instead of the one this person just deliberately
                    // named and created.
                    Task {
                        await activeGroupSession.refreshGroups()
                        activeGroupSession.activeGroupID = created.id
                    }
                })
            }
        }
    }

    private func incomingRequestRow(_ request: IncomingFriendRequest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.from.displayNameOrPhoneNumber)
                // Direct fix for a real gap: without this, a plain "be my
                // friend" request and one that also invites you into a
                // group rendered identically — see `IncomingFriendRequest
                // .linkedGroupName`'s own doc comment.
                if let linkedGroupName = request.linkedGroupName {
                    Text("Invites you to \(linkedGroupName)")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if respondingToID == request.friendshipID {
                ProgressView()
            } else {
                Button("Accept") { Task { await respond(to: request.friendshipID, accept: true) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Decline") { Task { await respond(to: request.friendshipID, accept: false) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func loadFriends() async {
        isLoadingFriends = true
        errorMessage = nil
        defer { isLoadingFriends = false }
        do {
            friendsList = try await AccountsAPIClient.getFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same two calls `FriendsListView.respond(to:accept:)` makes — not a
    /// shared helper, just reusing the same two one-line
    /// `AccountsAPIClient` methods that view already calls, since factoring
    /// out a shared function for two lines of `try await` would be more
    /// indirection than the duplication it removes.
    private func respond(to friendshipID: String, accept: Bool) async {
        respondingToID = friendshipID
        defer { respondingToID = nil }
        do {
            if accept {
                try await AccountsAPIClient.acceptFriendRequest(id: friendshipID)
            } else {
                try await AccountsAPIClient.declineFriendRequest(id: friendshipID)
            }
            // Accepting a request tied to a group invite (per
            // routes/friends.js/auth.js's invite-consent design) is what
            // can make `groups` non-empty for the very first time — refresh
            // it every time, accept or decline, so a decline also clears
            // this row out of `friendsList` via the `loadFriends()` refresh
            // below and an accept transitions straight into the main app
            // the instant `activeGroupSession.groups` picks up the new
            // group.
            await loadFriends()
            await activeGroupSession.refreshGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
