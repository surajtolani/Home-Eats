import SwiftUI
import SwiftData

/// "There should be a way to eliminate duplications" (direct user
/// request) — the recipe counterpart of `DuplicateRestaurantsView`, same
/// design; see that type's own doc comment for the full reasoning, which
/// applies here verbatim. Reachable from `RecipesHomeView`'s toolbar.
///
/// Only ever groups the account's own recipes (`source != .library ||
/// isSavedToCollection` — the same filter `RecipesHomeView.myRecipes`
/// itself uses) by an exact, non-empty `sourceURL` match OR a
/// case-insensitive, trimmed title match — the identical two rules
/// `RecipeDuplicateChecker.existingMatch(title:sourceURL:in:)` uses to stop
/// a *new* duplicate from being added going forward; this is that same
/// rule applied backward, to whatever's already in the library. A recipe
/// can only ever land in one group (`sourceURL` checked first, same
/// priority as the forward-looking check), so a title match never
/// double-counts one already grouped by URL.
struct DuplicateRecipesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.createdAt) private var allRecipes: [Recipe]

    private var myRecipes: [Recipe] {
        allRecipes.filter { $0.source != .library || $0.isSavedToCollection }
    }

    private var duplicateGroups: [[Recipe]] {
        var remaining = myRecipes
        var groups: [[Recipe]] = []

        // sourceURL groups first — the stronger signal, same priority
        // order as `RecipeDuplicateChecker`.
        let byURL = Dictionary(grouping: remaining.filter { ($0.sourceURL?.isEmpty == false) }) { $0.sourceURL! }
        for group in byURL.values where group.count > 1 {
            groups.append(group.sorted { $0.createdAt < $1.createdAt })
            remaining.removeAll { recipe in group.contains { $0.id == recipe.id } }
        }

        let byTitle = Dictionary(grouping: remaining) { $0.title.trimmingCharacters(in: .whitespaces).lowercased() }
        for group in byTitle.values where group.count > 1 {
            groups.append(group.sorted { $0.createdAt < $1.createdAt })
        }

        return groups.sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
    }

    var body: some View {
        NavigationStack {
            List {
                if duplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No Duplicates Found",
                        systemImage: "checkmark.circle",
                        description: Text("Every recipe in your collection has a distinct name and source.")
                    )
                } else {
                    ForEach(duplicateGroups, id: \.first?.id) { group in
                        Section {
                            ForEach(group) { recipe in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipe.title)
                                        if let sourceURL = recipe.sourceURL, !sourceURL.isEmpty {
                                            Text(sourceURL)
                                                .font(.brandCaption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if recipe.id == group.first?.id {
                                        Text("Oldest").font(.brandCaption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets { delete(group[index]) }
                            }
                        } header: {
                            Text("\(group.first?.title ?? "") — \(group.count) copies")
                        } footer: {
                            Button(role: .destructive) {
                                for recipe in group.dropFirst() { delete(recipe) }
                            } label: {
                                Text("Keep Oldest, Delete Rest")
                            }
                            .font(.brandSubheadline)
                        }
                    }
                }
            }
            .navigationTitle("Duplicate Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Identical to `RecipesHomeView`'s own swipe-to-delete on "My
    /// Recipes"/"Favorites" — see that screen's `.onDelete` for the twin
    /// implementation this deliberately mirrors, same reasoning as
    /// `DuplicateRestaurantsView.delete(_:)` for not factoring it out.
    private func delete(_ recipe: Recipe) {
        CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
        if let backendRecipeID = recipe.backendRecipeID {
            Task { try? await AccountsAPIClient.deleteRecipe(id: backendRecipeID) }
        }
        modelContext.delete(recipe)
    }
}
