import SwiftUI
import SwiftData

struct RecipesHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.title) private var allRecipes: [Recipe]
    @Query private var history: [MealHistoryEntry]

    @State private var section: Section = .mine
    @State private var searchText = ""
    @State private var showImportSheet = false
    @State private var showManualEditor = false

    enum Section: String, CaseIterable, Identifiable {
        case mine = "My Recipes"
        case library = "Library"
        var id: String { rawValue }
    }

    private var myRecipes: [Recipe] {
        allRecipes.filter { $0.source != .library || $0.isSavedToCollection }
    }
    private var libraryRecipes: [Recipe] {
        allRecipes.filter { $0.source == .library && !$0.isSavedToCollection }
    }

    private var displayedRecipes: [Recipe] {
        let base = section == .mine ? myRecipes : libraryRecipes
        let filtered = searchText.isEmpty
            ? base
            : base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return section == .mine ? RecommendationEngine.rank(recipes: filtered, history: history) : filtered
    }

    var body: some View {
        VStack {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                if displayedRecipes.isEmpty {
                    ContentUnavailableView(
                        section == .mine ? "No Recipes Yet" : "Library is Empty",
                        systemImage: "book.closed",
                        description: Text(
                            section == .mine
                                ? "Add your own recipe or import one from a link."
                                : "Check back soon for more built-in recipes."
                        )
                    )
                }
                if section == .mine {
                    // Swipe-to-delete only makes sense here — a Library
                    // recipe the user hasn't saved isn't theirs to delete,
                    // so the row wouldn't do anything if swiped there.
                    ForEach(displayedRecipes) { recipe in
                        NavigationLink {
                            RecipeDetailView(recipe: recipe)
                        } label: {
                            RecipeRow(recipe: recipe)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let recipe = displayedRecipes[index]
                            if recipe.source == .library {
                                // "Un-save" a library recipe instead of deleting the shared copy.
                                recipe.isSavedToCollection = false
                            } else {
                                CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
                                modelContext.delete(recipe)
                            }
                        }
                    }
                } else {
                    ForEach(displayedRecipes) { recipe in
                        NavigationLink {
                            RecipeDetailView(recipe: recipe)
                        } label: {
                            RecipeRow(recipe: recipe)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $searchText, prompt: "Search recipes")
        .navigationTitle("Recipes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showManualEditor = true
                    } label: {
                        Label("Type a Recipe", systemImage: "square.and.pencil")
                    }
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("Import from URL", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showManualEditor) {
            RecipeEditorView()
        }
        .sheet(isPresented: $showImportSheet) {
            RecipeImportView()
        }
    }
}

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recipe.title).font(.headline)
            HStack(spacing: 8) {
                if recipe.totalMinutes > 0 {
                    Label("\(recipe.totalMinutes) min", systemImage: "clock")
                }
                Label("serves \(recipe.servings)", systemImage: "person.2")
                if recipe.source == .imported {
                    Label("imported", systemImage: "link")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
