import SwiftUI
import SwiftData

struct RecipesHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recipe.title) private var allRecipes: [Recipe]
    @Query private var history: [MealHistoryEntry]

    @State private var section: Section = .mine
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var showImportSheet = false
    @State private var showManualEditor = false
    @State private var showAIImportSheet = false
    @State private var showRecommendSheet = false
    @State private var quickAddRecipe: Recipe?

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
        var base = section == .mine ? myRecipes : libraryRecipes
        if !searchText.isEmpty {
            base = base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        if showFavoritesOnly {
            base = base.filter { $0.isFavorite }
        }
        return section == .mine ? RecommendationEngine.rank(recipes: base, history: history) : base
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                if displayedRecipes.isEmpty {
                    ContentUnavailableView(
                        emptyStateTitle,
                        systemImage: showFavoritesOnly ? "heart" : "book.closed",
                        description: Text(emptyStateDescription)
                    )
                }
                if section == .mine {
                    // Swipe-to-delete only makes sense here — a Library
                    // recipe the user hasn't saved isn't theirs to delete,
                    // so the row wouldn't do anything if swiped there.
                    ForEach(displayedRecipes) { recipe in
                        recipeCard(recipe)
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
                        recipeCard(recipe)
                    }
                }
            }
            .listStyle(.plain)
        }
        .searchable(text: $searchText, prompt: "Search recipes")
        .navigationTitle("Recipes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                }
                .tint(.brandTerracotta)
            }
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
                    Button {
                        showAIImportSheet = true
                    } label: {
                        Label("Add from Photo or Notes", systemImage: "camera.viewfinder")
                    }
                    Divider()
                    Button {
                        showRecommendSheet = true
                    } label: {
                        Label("Recommend a Meal", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showManualEditor) {
            RecipeEditorView()
        }
        .sheet(isPresented: $showAIImportSheet) {
            RecipeAIImportView()
        }
        .sheet(isPresented: $showRecommendSheet) {
            RecommendMealView()
        }
        .sheet(isPresented: $showImportSheet) {
            RecipeImportView()
        }
        .sheet(item: $quickAddRecipe) { recipe in
            QuickAddToPlanSheet(recipe: recipe)
        }
    }

    private var emptyStateTitle: String {
        if showFavoritesOnly { return "No Favorites Yet" }
        return section == .mine ? "No Recipes Yet" : "Library is Empty"
    }

    private var emptyStateDescription: String {
        if showFavoritesOnly { return "Tap the heart on a recipe to save it here." }
        return section == .mine
            ? "Add your own recipe or import one from a link."
            : "Check back soon for more built-in recipes."
    }

    /// A photo card (image on top, title + details below), a `NavigationLink`
    /// to the recipe, with two floating buttons over the image: a heart to
    /// favorite, a "+" to jump straight to `QuickAddToPlanSheet`. Both are
    /// applied as `.overlay`s on the *outside* of the `NavigationLink`, not
    /// nested inside its `label:` — a `Button` inside a `NavigationLink`'s
    /// label fires both the button's action and the navigation on the same
    /// tap, so `RecipeCardContent` itself carries no interactive controls at
    /// all, only the image/title/meta visuals.
    @ViewBuilder
    private func recipeCard(_ recipe: Recipe) -> some View {
        NavigationLink {
            RecipeDetailView(recipe: recipe)
        } label: {
            RecipeCardContent(recipe: recipe)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            CircularIconButton(systemImage: "plus", tint: .white) {
                quickAddRecipe = recipe
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            CircularIconButton(
                systemImage: recipe.isFavorite ? "heart.fill" : "heart",
                tint: recipe.isFavorite ? .brandTerracotta : .white
            ) {
                recipe.isFavorite.toggle()
            }
            .padding(8)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

private struct RecipeCardContent: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecipeThumbnail(recipe: recipe)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if recipe.totalMinutes > 0 {
                        Label("\(recipe.totalMinutes) min", systemImage: "clock")
                    }
                    Label("serves \(recipe.servings)", systemImage: "person.2")
                    if recipe.source == .imported {
                        Label("imported", systemImage: "link")
                    }
                }
                .font(.brandCaption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(Color.brandCream)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }
}

/// A small circular button floating over a photo — a translucent dark disc
/// so a white icon reads clearly regardless of what's underneath it.
private struct CircularIconButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.brandCallout)
                .foregroundStyle(tint)
                .padding(8)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
