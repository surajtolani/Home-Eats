import SwiftUI

/// The caller's friends list — accepted friends, plus separate incoming/
/// outgoing pending requests, and an "Add Friend" action. Fetched live from
/// `GET /friends` every time this view appears rather than mirrored into
/// SwiftData: friends/groups are the one part of this feature with no
/// offline-editing need (you can't usefully "add a friend" while offline
/// anyway, since it's a request to a server-side account) and the backend
/// is already the sole source of truth for who's friends with whom — see
/// the wiring task's own notes on why this deliberately has no local model.
struct FriendsListView: View {
    @State private var friendsList: FriendsList?
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showAddFriend = false
    /// Any failure from an action taken *after* the list has already loaded
    /// once — a failed add-friend pick, or a failed accept/decline — shown
    /// as a non-blocking `.alert` instead of through `errorMessage` below.
    /// `errorMessage` replaces this entire list's content the moment it's
    /// set (see the `if/else if` chain in `body`), which is the right
    /// behavior for "the very first load failed, there's nothing to show
    /// yet" but would otherwise blank out a friends list someone can
    /// already see just because one accept/decline tap or one add-friend
    /// pick happened to fail.
    @State private var actionFailure: String?

    var body: some View {
        List {
            if isLoading && friendsList == nil {
                ProgressView()
            } else if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            } else if let friendsList {
                if !friendsList.incomingRequests.isEmpty {
                    Section("Requests") {
                        ForEach(friendsList.incomingRequests) { request in
                            incomingRequestRow(request)
                        }
                    }
                }
                if !friendsList.outgoingRequests.isEmpty {
                    Section("Sent") {
                        ForEach(friendsList.outgoingRequests) { request in
                            HStack {
                                Text(request.to.displayNameOrPhoneNumber)
                                Spacer()
                                // No cancel action here on purpose: the
                                // backend has no "withdraw my own outgoing
                                // request" route (only the recipient can
                                // accept/decline — see
                                // `OutgoingFriendRequest`'s doc comment), so
                                // this is deliberately read-only rather than
                                // a button that would always fail.
                                Text("Pending")
                                    .font(.brandCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Friends") {
                    if friendsList.friends.isEmpty {
                        Text("No friends yet — add one by phone number below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(friendsList.friends) { friend in
                        friendRow(friend)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddFriend = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        // Reuses the exact same "search Contacts by name, or type a phone
        // number" sheet the group-invite flows already share (see
        // `ContactOrPhoneNumberPickerView`'s doc comment) — a plain
        // phone-number-only `AddFriendView` used to live here, replaced
        // outright rather than kept alongside this, per the user's own
        // request to search by name too, "via a search bar vs the + button."
        // The "+" button still opens the sheet (there's no natural place for
        // an always-visible inline search bar above "Requests"/"Sent"
        // sections that also need to render), but what it opens now leads
        // with a search bar instead of a single bare text field.
        .sheet(isPresented: $showAddFriend, onDismiss: { Task { await load() } }) {
            ContactOrPhoneNumberPickerView(onPick: handlePicked)
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

    /// Sends a friend request for whatever `ContactOrPhoneNumberPickerView`
    /// handed back — the picker itself has no concept of "friend request"
    /// vs. "group invite" (see its own doc comment); this is the Friends-
    /// specific half of that contract. Fired as its own `Task` rather than
    /// awaited inline: `onPick` isn't `async`, matching every other caller
    /// of this same picker.
    private func handlePicked(_ picked: PickedPhoneContact) {
        Task {
            do {
                try await AccountsAPIClient.sendFriendRequest(phoneNumber: picked.phoneNumber)
                await load()
            } catch {
                actionFailure = error.localizedDescription
            }
        }
    }

    /// Name only — no phone-number subtitle. A friend's phone number used to
    /// show here as a secondary line whenever a display name was also set,
    /// but a friend should be identified by who they are, not by the number
    /// tied to their account; `displayNameOrPhoneNumber`'s phone-number
    /// fallback still covers the (now rare, since a name is required going
    /// forward) case of a friend who somehow has no name at all.
    private func friendRow(_ user: PublicUser) -> some View {
        Text(user.displayNameOrPhoneNumber)
    }

    private func incomingRequestRow(_ request: IncomingFriendRequest) -> some View {
        HStack {
            Text(request.from.displayNameOrPhoneNumber)
            Spacer()
            Button("Accept") { Task { await respond(to: request.friendshipID, accept: true) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Decline") { Task { await respond(to: request.friendshipID, accept: false) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // Only a *first* load's failure blanks the screen down to an error
        // + Retry button (there's genuinely nothing else to show yet). A
        // refresh failure (pull-to-refresh, or the re-fetch after an
        // accept/decline/add-friend action below) with an already-loaded
        // list on screen goes through `actionFailure`'s non-blocking alert
        // instead, leaving whatever was already showing exactly as it was —
        // same reasoning as `actionFailure`'s own doc comment.
        let isFirstLoad = friendsList == nil
        do {
            friendsList = try await AccountsAPIClient.getFriends()
        } catch {
            if isFirstLoad {
                errorMessage = error.localizedDescription
            } else {
                actionFailure = error.localizedDescription
            }
        }
    }

    private func respond(to friendshipID: String, accept: Bool) async {
        do {
            if accept {
                try await AccountsAPIClient.acceptFriendRequest(id: friendshipID)
            } else {
                try await AccountsAPIClient.declineFriendRequest(id: friendshipID)
            }
            await load()
        } catch {
            // Not `errorMessage` — see `actionFailure`'s doc comment. A
            // failed accept/decline tap shouldn't blank out the whole list
            // the user was just looking at.
            actionFailure = error.localizedDescription
        }
    }
}
