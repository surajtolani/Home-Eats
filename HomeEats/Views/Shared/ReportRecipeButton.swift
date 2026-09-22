import SwiftUI

/// A toolbar button that flags a recipe someone else added (a Library
/// entry, a friend/group share) for a human to review — direct fix for a
/// real gap: the master Recipe Library shows every signed-in user's
/// published recipes to every other one, with previously no way to flag a
/// recipe that's spam, offensive, or otherwise not what it claims to be.
/// Presents a `confirmationDialog` of reasons rather than a free-text
/// field — nothing downstream reads free text yet (see
/// `AccountsAPIClient.reportRecipe(id:reason:)`'s own doc comment), so
/// asking for it would just be an unused field. Shows a brief "Reported"
/// confirmation in place of the flag icon rather than silently succeeding,
/// so tapping it doesn't feel like it did nothing.
struct ReportRecipeButton: View {
    let recipeID: String

    @State private var isPickingReason = false
    @State private var didReport = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if didReport {
                Label("Reported", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.iconOnly)
            } else {
                Button {
                    isPickingReason = true
                } label: {
                    Image(systemName: "flag")
                }
            }
        }
        .confirmationDialog("Report This Recipe", isPresented: $isPickingReason, titleVisibility: .visible) {
            Button("Inappropriate content") { report(.inappropriate) }
            Button("Spam or misleading") { report(.spamOrMisleading) }
            Button("Other") { report(.other) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Send Report", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func report(_ reason: RecipeReportReason) {
        Task {
            do {
                try await AccountsAPIClient.reportRecipe(id: recipeID, reason: reason)
                didReport = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
