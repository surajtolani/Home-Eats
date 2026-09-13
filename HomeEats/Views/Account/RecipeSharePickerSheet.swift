import SwiftUI
import SwiftData

/// Presented from `RecipeDetailView`'s Share action — pick any number of
/// friends and/or groups to share this recipe with. The very first share of
/// a given local recipe auto-creates its backend counterpart
/// (`POST /recipe-library`) since local recipes are local-first and only
/// ever pushed to the backend the moment someone actually shares one (see
/// `Recipe.backendRecipeID`'s doc comment) — every share after that first
/// one reuses the same backend id instead of creating a duplicate row.
struct RecipeSharePickerSheet: View {
    @Bindable var recipe: Recipe

    @Environment(\.dismiss) private var dismiss

    @State private var friends: [PublicUser] = []
    @State private var groups: [GroupSummary] = []
    @State private var isLoadingTargets = false
    @State private var loadError: String?
    @State private var errorMessage: String?
    /// The id (a friend's user id, or a group's id) currently mid-share —
    /// used to show a per-row spinner and to disable every row while a
    /// share is in flight, since `ensureBackendRecipeID()` mutates shared
    /// state (`recipe.backendRecipeID`) that a second simultaneous tap
    /// could race.
    @State private var sharingTargetID: String?
    @State private var sharedTargetIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if isLoadingTargets {
                    ProgressView()
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry") { Task { await loadTargets() } }
                } else {
                    Section("Friends") {
                        if friends.isEmpty {
                            Text("No friends yet.").foregroundStyle(.secondary)
                        }
                        ForEach(friends) { friend in
                            shareRow(id: friend.id, title: friend.displayNameOrPhoneNumber) {
                                await share(userID: friend.id)
                            }
                        }
                    }
                    Section("Groups") {
                        if groups.isEmpty {
                            Text("No groups yet.").foregroundStyle(.secondary)
                        }
                        ForEach(groups) { group in
                            shareRow(id: group.id, title: group.name) {
                                await share(groupID: group.id)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Share Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadTargets() }
        }
    }

    private func shareRow(id: String, title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if sharingTargetID == id {
                    ProgressView()
                } else if sharedTargetIDs.contains(id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .disabled(sharingTargetID != nil || sharedTargetIDs.contains(id))
    }

    private func loadTargets() async {
        isLoadingTargets = true
        loadError = nil
        defer { isLoadingTargets = false }
        do {
            async let friendsResult = AccountsAPIClient.getFriends()
            async let groupsResult = AccountsAPIClient.getGroups()
            friends = try await friendsResult.friends
            groups = try await groupsResult
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Returns the backend recipe id to share, creating it first if this
    /// local recipe has never been shared before. Setting
    /// `recipe.backendRecipeID` here (a `@Bindable` write) is what makes
    /// every subsequent share — in this sheet or a later one — skip
    /// straight to sharing instead of creating a second backend row for the
    /// same local recipe.
    private func ensureBackendRecipeID() async throws -> String {
        if let existing = recipe.backendRecipeID { return existing }
        let created = try await AccountsAPIClient.createRecipe(RecipeLibraryPayload(recipe: recipe))
        recipe.backendRecipeID = created.id
        return created.id
    }

    private func share(userID: String) async {
        errorMessage = nil
        sharingTargetID = userID
        defer { sharingTargetID = nil }
        do {
            let recipeID = try await ensureBackendRecipeID()
            try await AccountsAPIClient.shareRecipe(id: recipeID, withUserID: userID)
            sharedTargetIDs.insert(userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(groupID: String) async {
        errorMessage = nil
        sharingTargetID = groupID
        defer { sharingTargetID = nil }
        do {
            let recipeID = try await ensureBackendRecipeID()
            try await AccountsAPIClient.shareRecipe(id: recipeID, withGroupID: groupID)
            sharedTargetIDs.insert(groupID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
