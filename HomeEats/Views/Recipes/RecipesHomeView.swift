import SwiftUI
import SwiftData
import UIKit // For `SharedRecipeEntryThumbnail`'s `UIImage(data:)` decode.

struct RecipesHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query(sort: \Recipe.title) private var allRecipes: [Recipe]
    @Query private var history: [MealHistoryEntry]

    @State private var section: Section = .mine
    @State private var searchText = ""
    @State private var showImportSheet = false
    @State private var showManualEditor = false
    @State private var showAIImportSheet = false
    @State private var showRecommendSheet = false
    @State private var quickAddRecipe: Recipe?

    // MARK: Shared (backend recipe-sharing) state
    //
    // Unlike `.mine`/`.favorites`/`.library` above, "Shared" isn't backed by
    // `allRecipes` at all — recipes shared with the caller live only on the
    // backend until explicitly saved (see `RecipeSource.shared`'s doc
    // comment), so this section fetches `GET /recipe-library/shared-with-me`
    // live instead, the same "no local mirror, backend is the source of
    // truth" reasoning `FriendsListView`/`GroupsListView` already use for
    // friends/groups.
    @State private var sharedRecipes: [SharedRecipeEntry] = []
    @State private var isLoadingShared = false
    @State private var sharedLoadError: String?
    /// Shares already saved into a local `Recipe` this session, so their row
    /// can show a checkmark instead of a "Save to My Recipes" button that
    /// would otherwise happily create a second local copy on a second tap.
    @State private var savedShareIDs: Set<String> = []
    @State private var showSignIn = false

    enum Section: String, CaseIterable, Identifiable {
        case mine = "My Recipes"
        case favorites = "Favorites"
        case library = "Library"
        case shared = "Shared"
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
        case .shared: base = [] // Rendered separately — see `sharedSectionContent`.
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
                if section == .shared {
                    sharedSectionContent
                } else {
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
                                    // Fires the backend delete immediately,
                                    // inline — same "immediate, online-only"
                                    // pattern `GroupSyncService` already uses
                                    // for adopt/accept, not a queued pending-
                                    // delete state (see
                                    // `PersonalLibrarySyncService`'s own doc
                                    // comment on why this feature skips that
                                    // machinery). Captured before the local
                                    // delete below, since `recipe` isn't safe
                                    // to read from afterward; `nil` (never
                                    // synced) just means there's nothing on
                                    // the server to delete.
                                    if let backendRecipeID = recipe.backendRecipeID {
                                        Task { try? await AccountsAPIClient.deleteRecipe(id: backendRecipeID) }
                                    }
                                    modelContext.delete(recipe)
                                }
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
        .sheet(isPresented: $showSignIn) {
            AccountSignInView()
        }
        .onChange(of: section) { _, newValue in
            if newValue == .shared {
                Task { await loadSharedRecipes() }
            }
        }
        // The signed-in identity can change out from under this view at any
        // time — `RecipesHomeView` lives inside `RootView`'s always-alive
        // `TabView`, so it never gets torn down/recreated on sign-out or a
        // fresh sign-in the way a pushed screen would. Without this,
        // `sharedRecipes`/`savedShareIDs` fetched for one account would just
        // sit there and render as if they belonged to whoever's signed in
        // now. Both `currentUser?.id` (covers switching to a *different*
        // signed-in account) and `isSignedIn` (covers sign-out specifically,
        // where `currentUser` also goes `nil` but there's no "different id"
        // to compare against) are watched since either alone misses a case.
        .onChange(of: accountSession.currentUser?.id) { _, _ in
            sharedRecipes = []
            savedShareIDs = []
            sharedLoadError = nil
            if section == .shared && accountSession.isSignedIn {
                Task { await loadSharedRecipes() }
            }
        }
        .onChange(of: accountSession.isSignedIn) { _, isSignedIn in
            if !isSignedIn {
                // Sign-out: drop stale rows immediately. `sharedSectionContent`
                // already renders the "Sign In to See Shared Recipes" state
                // whenever `!accountSession.isSignedIn`, so clearing here is
                // enough to avoid a stale list ever being visible — no
                // separate signed-out state needed beyond that existing check.
                sharedRecipes = []
                savedShareIDs = []
                sharedLoadError = nil
                isLoadingShared = false
            }
        }
        // Opportunistic personal-library sync on top of `RootView`'s own
        // launch/sign-in trigger — see `PersonalLibrarySyncService`'s own
        // doc comment for the full design. Visiting this tab is exactly
        // the kind of natural moment worth syncing on, since it's when a
        // recovered recipe would actually become visible.
        .task(id: accountSession.isSignedIn) {
            guard accountSession.isSignedIn else { return }
            await PersonalLibrarySyncService.sync(modelContext: modelContext)
        }
    }

    // MARK: Shared section

    /// The "Shared" segment's content — separate from the `displayedRecipes`
    /// `ForEach` above since this isn't rendering local `Recipe` rows at
    /// all, just whatever `GET /recipe-library/shared-with-me` last
    /// returned.
    @ViewBuilder
    private var sharedSectionContent: some View {
        if !accountSession.isSignedIn {
            ContentUnavailableView(
                "Sign In to See Shared Recipes",
                systemImage: "person.2",
                description: Text("Friends and groups can share recipes with you once you're signed in.")
            )
            Button("Sign In") { showSignIn = true }
        } else if isLoadingShared {
            ProgressView()
        } else if let sharedLoadError {
            Text(sharedLoadError).foregroundStyle(.red)
            Button("Retry") { Task { await loadSharedRecipes() } }
        } else if sharedRecipes.isEmpty {
            ContentUnavailableView(
                "No Shared Recipes Yet",
                systemImage: "square.and.arrow.up",
                description: Text("Recipes friends or groups share with you will show up here.")
            )
        } else {
            ForEach(sharedRecipes) { entry in
                sharedRecipeRow(entry)
            }
        }
    }

    private func sharedRecipeRow(_ entry: SharedRecipeEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Shows the sender's photo before the recipe is even saved —
            // this row used to have no thumbnail at all (nothing here ever
            // had a photo to show before `photoBase64` existed), so this is
            // new, not a fix to something that regressed. Kept as its own
            // small view (`SharedRecipeEntryThumbnail` below) rather than
            // reusing `RecipeThumbnail`, which takes a local `Recipe` and
            // has no reason to learn about a wire-format `SharedRecipeEntry`
            // that doesn't exist as a `Recipe` until the moment it's saved.
            SharedRecipeEntryThumbnail(photoData: entry.photoData)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.brandHeadline)
                Text(entry.sharedByCaption)
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                if savedShareIDs.contains(entry.id) {
                    Label("Saved to My Recipes", systemImage: "checkmark.circle.fill")
                        .font(.brandCaption)
                        .foregroundStyle(.green)
                } else {
                    Button("Save to My Recipes") { saveSharedRecipe(entry) }
                        .font(.brandCaption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadSharedRecipes() async {
        isLoadingShared = true
        sharedLoadError = nil
        defer { isLoadingShared = false }
        do {
            sharedRecipes = try await AccountsAPIClient.getSharedRecipes()
        } catch {
            sharedLoadError = error.localizedDescription
        }
    }

    /// Materializes a shared recipe into a local `Recipe` — the "Shared"
    /// counterpart to `RecipeDetailView`'s existing Library-save path
    /// (`recipe.isSavedToCollection = true`), except a shared recipe has no
    /// pre-existing local row to flip that flag on (see
    /// `RecipeSource.shared`'s doc comment), so this creates one instead,
    /// already saved (`isSavedToCollection` defaults to `true`) and tagged
    /// with the backend id it came from so re-sharing it later reuses that
    /// same backend recipe rather than creating a duplicate.
    ///
    /// `photoData: entry.photoData` is what actually fixes this recipe's
    /// photo showing up at all: `entry.photoData` decodes `entry.photoBase64`
    /// (see `SharedRecipeEntry`'s own doc comment) straight into the same
    /// `Data?` `RecipeThumbnail` already knows how to render for any other
    /// `Recipe` — no new display code needed here, since a `.shared` recipe
    /// becomes an ordinary local `Recipe` the moment it's saved, and every
    /// existing recipe list/detail view already shows `photoData` when
    /// present. `nil` when the shared recipe had no photo at all, same as
    /// every other recipe source.
    private func saveSharedRecipe(_ entry: SharedRecipeEntry) {
        // `sourceURL`/`imageName` here fix a real gap: same bug class
        // `photoData`/`entry.photoBase64` had before that field existed —
        // an imported recipe's source-page link and photo never made it
        // across the wire at all until `SharedRecipeEntry.sourceURL`/
        // `.imageName` did.
        let recipe = Recipe(
            title: entry.title,
            source: .shared,
            sourceURL: entry.sourceURL,
            summary: entry.summary,
            instructions: entry.instructions,
            ingredients: entry.ingredients.map {
                RecipeIngredientEntry(name: $0.name, quantity: $0.quantity, unit: $0.unit)
            },
            servings: entry.servings ?? 4,
            prepMinutes: entry.prepMinutes ?? 0,
            cookMinutes: entry.cookMinutes ?? 0,
            tags: ["Shared"],
            imageName: entry.imageName,
            photoData: entry.photoData,
            backendRecipeID: entry.recipeID
        )
        modelContext.insert(recipe)
        savedShareIDs.insert(entry.id)
    }

    private var emptyStateTitle: String {
        switch section {
        case .mine: return "No Recipes Yet"
        case .favorites: return "No Favorites Yet"
        case .library: return "Library is Empty"
        case .shared: return "No Shared Recipes Yet" // Unused — see `sharedSectionContent`.
        }
    }

    private var emptyStateDescription: String {
        switch section {
        case .mine: return "Add your own recipe or import one from a link."
        case .favorites: return "Tap the heart on a recipe to save it here."
        case .library: return "Check back soon for more built-in recipes."
        case .shared: return "" // Unused — see `sharedSectionContent`.
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
                    if recipe.source == .shared {
                        Label("shared", systemImage: "person.2")
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

/// A small square photo for one `sharedRecipeRow` — deliberately much
/// simpler than `RecipeThumbnail` (no remote-URL/bundled-asset cases: a
/// `SharedRecipeEntry` that hasn't been saved yet only ever has a decoded
/// photo or nothing), but the same placeholder look (sage tint, a plain
/// fork-and-knife glyph) so a shared recipe with no photo doesn't look
/// broken or different from any other "no photo" recipe elsewhere in this
/// app.
private struct SharedRecipeEntryThumbnail: View {
    let photoData: Data?

    var body: some View {
        Group {
            if let photoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.brandSage.opacity(0.15)
                    Image(systemName: "fork.knife")
                        .foregroundStyle(Color.brandSage)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
