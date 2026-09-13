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
        .sheet(isPresented: $showAddFriend, onDismiss: { Task { await load() } }) {
            AddFriendView()
        }
    }

    private func friendRow(_ user: PublicUser) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(user.displayNameOrPhoneNumber)
            if user.displayName?.isEmpty == false {
                Text(user.phoneNumber).font(.brandCaption).foregroundStyle(.secondary)
            }
        }
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
        do {
            friendsList = try await AccountsAPIClient.getFriends()
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }
}

/// "Add Friend" by phone number — its own small sheet rather than an inline
/// row in `FriendsListView`, matching how this app already pulls a
/// multi-field add flow into its own sheet elsewhere (e.g.
/// `RecipeAIImportView`) rather than cramming it into a list.
private struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phoneNumber = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var canSend: Bool {
        PhoneNumberFormatting.e164(from: phoneNumber) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone number", text: $phoneNumber)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                } footer: {
                    Text("They'll need to accept before you're friends. If they haven't joined Home Eats yet, they'll see your request waiting for them the moment they sign up — same as anyone else's.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                    }
                }
            }
        }
    }

    private func send() async {
        guard let e164 = PhoneNumberFormatting.e164(from: phoneNumber) else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            try await AccountsAPIClient.sendFriendRequest(phoneNumber: e164)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
