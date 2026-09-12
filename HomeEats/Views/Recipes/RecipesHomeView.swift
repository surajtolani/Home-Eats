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
    @State private var showAIImportSheet = false
    @State private var showRecommendSheet = false
    @State private var quickAddRecipe: Recipe?

    enum Section: String, CaseIterable, Identifiable {
        case mine = "My Recipes"
        case favorites = "Favorites"
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
        var base: [Recipe]
        switch section {
        case .mine: base = myRecipes
        case .favorites: base = myRecipes.filter { $0.isFavorite }
        case .library: base = libraryRecipes
        }
        if !searchText.isEmpty {
            base = base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        // Library stays alphabetical (its own @Query sort); "mine" and
        // "favorites" are both really views onto the same recipes, so both
        // get the same recency-weighted ranking.
        return section == .library ? base : RecommendationEngine.rank(recipes: base, history: history)
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
                        systemImage: section == .favorites ? "heart" : "book.closed",
                        description: Text(emptyStateDescription)
                    )
                }
                if section == .library {
                    ForEach(displayedRecipes) { recipe in
                        recipeCard(recipe)
                    }
                } else {
                    // Swipe-to-delete only makes sense for "mine"/"favorites"
                    // — a Library recipe the user hasn't saved isn't theirs
                    // to delete, so the row wouldn't do anything if swiped
                    // there.
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
                Menu {
                    Button {
                        presentAfterMenuDismiss { showManualEditor = true }
                    } label: {
                        Label("Type a Recipe", systemImage: "square.and.pencil")
                    }
                    Button {
                        presentAfterMenuDismiss { showImportSheet = true }
                    } label: {
                        Label("Import from URL", systemImage: "link")
                    }
                    Button {
                        presentAfterMenuDismiss { showAIImportSheet = true }
                    } label: {
                        Label("Add from Photo or Notes", systemImage: "camera.viewfinder")
                    }
                    Divider()
                    Button {
                        presentAfterMenuDismiss { showRecommendSheet = true }
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
        switch section {
        case .mine: return "No Recipes Yet"
        case .favorites: return "No Favorites Yet"
        case .library: return "Library is Empty"
        }
    }

    private var emptyStateDescription: String {
        switch section {
        case .mine: return "Add your own recipe or import one from a link."
        case .favorites: return "Tap the heart on a recipe to save it here."
        case .library: return "Check back soon for more built-in recipes."
        }
    }

    /// A photo card (image on top, title + details below) with two floating
    /// buttons over the image: a heart to favorite, a "+" to jump straight
    /// to `QuickAddToPlanSheet`. Tapping the rest of the card opens the
    /// recipe — via a `NavigationLink` hidden in the background rather than
    /// wrapping the visible content directly, which is also what keeps
    /// List from drawing its usual chevron disclosure indicator on the row
    /// (that indicator is tied to the row's top-level content literally
    /// being a `NavigationLink`, not to whether tapping it navigates).
    /// The two buttons are separate `.overlay`s on the *outside* of this
    /// whole stack, not nested inside the link's label — a `Button` nested
    /// inside a `NavigationLink`'s label fires both the button's action and
    /// the navigation on the same tap.
    @ViewBuilder
    private func recipeCard(_ recipe: Recipe) -> some View {
        RecipeCardContent(recipe: recipe)
            .background {
                // `.background` proposes the primary view's size to this
                // content, but a NavigationLink only *accepts* that size if
                // asked to be flexible — without the explicit frame here it
                // shrinks to fit its own empty label, leaving only a sliver
                // of the card actually tappable.
                NavigationLink("") {
                    RecipeDetailView(recipe: recipe)
                }
                .opacity(0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
