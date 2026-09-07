import SwiftUI
import SwiftData

/// A searchable picker over the user's saved recipes and the built-in
/// library, used anywhere a day needs a recipe assigned (suggestion or
/// final decision). Recommendations (frequency/recency-based) surface first.
struct RecipePickerSheet: View {
    let onPick: (Recipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Recipe.title) private var allRecipes: [Recipe]
    @Query private var history: [MealHistoryEntry]

    @State private var searchText = ""

    private var myRecipes: [Recipe] { allRecipes.filter { $0.source != .library || $0.isSavedToCollection } }
    private var libraryRecipes: [Recipe] { allRecipes.filter { $0.source == .library && !$0.isSavedToCollection } }

    private var recommended: [Recipe] {
        Array(RecommendationEngine.rank(recipes: myRecipes, history: history).prefix(5))
    }

    private func matches(_ recipe: Recipe) -> Bool {
        searchText.isEmpty || recipe.title.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty && !recommended.isEmpty {
                    Section("Recommended for you") {
                        ForEach(recommended) { recipe in
                            row(for: recipe)
                        }
                    }
                }
                Section("My Recipes") {
                    let filtered = myRecipes.filter(matches)
                    if filtered.isEmpty {
                        Text("No saved recipes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { recipe in
                        row(for: recipe)
                    }
                }
                Section("Library") {
                    ForEach(libraryRecipes.filter(matches)) { recipe in
                        row(for: recipe)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search recipes")
            .navigationTitle("Choose a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(for recipe: Recipe) -> some View {
        Button {
            onPick(recipe)
            dismiss()
        } label: {
            VStack(alignment: .leading) {
                Text(recipe.title).foregroundStyle(.primary)
                if recipe.totalMinutes > 0 {
                    Text("\(recipe.totalMinutes) min • serves \(recipe.servings)")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
