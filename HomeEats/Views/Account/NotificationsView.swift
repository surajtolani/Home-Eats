import SwiftUI

/// Phase 5, Part 3's combined "things waiting on my response" feed —
/// `GET /notifications`, shown as one list mixing both pending kinds
/// (`friendRequests`/`groupInvites`) rather than as two separate screens,
/// mirroring the backend's own doc comment on that route: a single
/// notification bell/badge that doesn't need to know or care what kind of
/// thing is pending, only that something is. Reached from the notification
/// bell (`GroupTopBar`/its `NotificationBellButton`).
///
/// Reads `NotificationsSession.feed` directly rather than keeping its own
/// local `@State` copy of the list (unlike `FriendsListView`/`GroupsListView`,
/// which own their data outright) — this screen's whole point is to share
/// state with the bell's badge, so both stay in sync off one object; see
/// `NotificationsSession`'s own doc comment.
///
/// **Friend requests reuse `AccountsAPIClient.acceptFriendRequest`/
/// `declineFriendRequest` — the exact same calls
/// `FriendsListView.respond(to:accept:)` already makes** — rather than a
/// second, parallel implementation of "answer a friend request." Group
/// invites go through the new `acceptInvite`/`declineInvite` methods
/// instead (Phase 5 has no pre-existing call site for those to reuse).
///
/// Same non-blocking "don't blank the whole screen over one action's
/// failure" pattern as `FriendsListView.actionFailure`/
/// `GroupDetailView.actionFailure` — see either's own doc comment; a failed
/// accept/decline tap here shouldn't hide the rest of this list.
struct NotificationsView: View {
    @EnvironmentObject private var notificationsSession: NotificationsSession
    /// Accepting a group invite creates a real `GroupMembership`
    /// server-side — `refreshGroups()` afterward is what makes the
    /// newly-joined group actually show up in the group switcher right
    /// away, rather than only appearing whenever something else next
    /// happens to trigger a refresh (see that method's own doc comment on
    /// its normal triggers, which this adds one more of).
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionFailure: String?

    var body: some View {
        List {
            if isLoading && notificationsSession.feed == nil {
                ProgressView()
            } else if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            } else if let feed = notificationsSession.feed {
                if feed.friendRequests.isEmpty && feed.groupInvites.isEmpty {
                    ContentUnavailableView(
                        "You're All Caught Up",
                        systemImage: "checkmark.circle",
                        description: Text("Friend requests and group invites waiting on you will show up here.")
                    )
                }
                if !feed.friendRequests.isEmpty {
                    Section("Friend Requests") {
                        ForEach(feed.friendRequests) { request in
                            friendRequestRow(request)
                        }
                    }
                }
                if !feed.groupInvites.isEmpty {
                    Section("Group Invites") {
                        ForEach(feed.groupInvites) { invite in
                            groupInviteRow(invite)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
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

    private func friendRequestRow(_ request: IncomingFriendRequest) -> some View {
        HStack {
            Text(request.from.displayNameOrPhoneNumber)
            Spacer()
            Button("Accept") { Task { await respondToFriendRequest(request.friendshipID, accept: true) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Decline") { Task { await respondToFriendRequest(request.friendshipID, accept: false) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func groupInviteRow(_ invite: GroupInvite) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.group.name)
                Text("Invited by \(invite.invitedBy.displayNameOrPhoneNumber)")
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept") { Task { await respondToGroupInvite(invite.id, accept: true) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Decline") { Task { await respondToGroupInvite(invite.id, accept: false) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let isFirstLoad = notificationsSession.feed == nil
        await notificationsSession.refresh()
        // `refresh()` swallows its own error (see its own doc comment,
        // shared with the bell's badge, which must never show a hard error
        // state) — this screen is the one place that actually needs to
        // distinguish "still loading" from "the very first load failed," so
        // it re-derives that from the fetch's outcome (`feed` still `nil`
        // after a first attempt) rather than giving `refresh()` a second,
        // throwing variant just for this one caller.
        if isFirstLoad && notificationsSession.feed == nil {
            errorMessage = "Couldn't load your notifications. Check your connection and try again."
        }
    }

    private func respondToFriendRequest(_ friendshipID: String, accept: Bool) async {
        do {
            if accept {
                try await AccountsAPIClient.acceptFriendRequest(id: friendshipID)
            } else {
                try await AccountsAPIClient.declineFriendRequest(id: friendshipID)
            }
            await notificationsSession.refresh()
        } catch {
            actionFailure = error.localizedDescription
        }
    }

    private func respondToGroupInvite(_ inviteID: String, accept: Bool) async {
        do {
            if accept {
                try await AccountsAPIClient.acceptInvite(id: inviteID)
                await activeGroupSession.refreshGroups()
            } else {
                try await AccountsAPIClient.declineInvite(id: inviteID)
            }
            await notificationsSession.refresh()
        } catch {
            actionFailure = error.localizedDescription
        }
    }
}
