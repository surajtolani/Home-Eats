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

    // MARK: Master library (routes/recipeLibrary.js's GET/POST /recipe-library/master,/publish)
    //
    // Same "no local mirror, backend is the source of truth" reasoning as
    // `sharedRecipes` above — see that property's own doc comment.
    @State private var masterLibraryRecipes: [LibraryRecipeEntry] = []
    @State private var isLoadingMasterLibrary = false
    @State private var masterLibraryLoadError: String?
    @State private var savedLibraryEntryIDs: Set<String> = []
    /// Drives the Share sheet from a card's own icon (`recipeCard`'s doc
    /// comment) — `item:`-based rather than a bare `Bool` since which
    /// recipe to share is per-tap, not fixed like `RecipeDetailView`'s own
    /// single `@Bindable var recipe`.
    @State private var shareTargetRecipe: Recipe?
    /// Drives the "Add to Library" confirmation dialog the same way.
    @State private var publishTargetRecipe: Recipe?
    @State private var publishErrorMessage: String?
    /// Set right before presenting sign-in from a card's Share/Add-to-Library
    /// icon while signed out, so the sign-in sheet's `onDismiss:` knows which
    /// action to resume once it succeeds — same pattern as
    /// `RecipeDetailView.pendingShareAfterSignIn`, generalized to cover two
    /// possible actions instead of one.
    @State private var pendingCardAction: PendingCardAction?
    /// Backs `searchFieldRow`'s `TextField` — same "no way to dismiss the
    /// keyboard" fix as `RestaurantListView.isSearchFieldFocused`, applied
    /// here too since this screen copies that exact search-field pattern
    /// (see `searchFieldRow`'s own doc comment).
    @FocusState private var isSearchFieldFocused: Bool
    private enum PendingCardAction {
        case share(Recipe)
        case publish(Recipe)
    }

    enum Section: String, CaseIterable, Identifiable {
        case mine = "My Recipes"
        case favorites = "Favorites"
        case library = "Library"
        case shared = "Shared"
        var id: String { rawValue }
    }

    /// A custom inline search field, not `.searchable(...)` (what this used
    /// to be) — direct user request to move the "+" add-recipe menu from
    /// the top-right toolbar to sit right next to the search bar itself.
    /// `.searchable`'s system search field always spans the full toolbar
    /// width with nothing else in it, so there's no way to place a button
    /// beside it there; a plain `TextField` in the same `HStack` as the
    /// menu is what actually makes "next to the search bar" possible —
    /// same fix as `RestaurantListView.searchFieldRow`'s identical change.
    /// "Recommend a Meal" used to be the last item in the "+" menu below;
    /// direct user request to split it out into its own sparkles icon
    /// instead, matching `RestaurantListView.searchFieldRow`'s own
    /// sparkles ("Ask for a Restaurant") + plus pair exactly. The extra
    /// `Spacer().frame(width: 6)` between the two (also added to
    /// `RestaurantListView.searchFieldRow`, same request) widens just that
    /// one gap — every other pair in this row keeps the plain 8pt
    /// `HStack` spacing.
    private var searchFieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search recipes", text: $searchText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFieldFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Button {
                showRecommendSheet = true
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recommend a Meal")
            Spacer().frame(width: 6)
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
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .accessibilityLabel("Add a Recipe")
        }
        .foregroundStyle(.primary)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.vertical, 8)
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

            searchFieldRow

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
                        // The bundled built-in recipes above, then the
                        // master library (community-published, "added by")
                        // below — see `masterLibrarySectionContent`'s own
                        // doc comment.
                        masterLibrarySectionContent
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
            // Same "no way to dismiss the keyboard" fix as
            // `RestaurantListView`'s identical `List` modifier — see that
            // one's own doc comment.
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle("Recipes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
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
        .sheet(item: $shareTargetRecipe) { recipe in
            RecipeSharePickerSheet(recipe: recipe)
        }
        .confirmationDialog(
            "Add to Library",
            isPresented: Binding(get: { publishTargetRecipe != nil }, set: { if !$0 { publishTargetRecipe = nil } }),
            titleVisibility: .visible,
            presenting: publishTargetRecipe
        ) { recipe in
            Button("Add with My Name") { publish(recipe, anonymous: false) }
            Button("Add Anonymously") { publish(recipe, anonymous: true) }
            Button("Cancel", role: .cancel) {}
        } message: { recipe in
            Text("Everyone on Home Eats will be able to see \"\(recipe.title)\" in the Library.")
        }
        .alert(
            "Couldn't add to Library",
            isPresented: Binding(get: { publishErrorMessage != nil }, set: { if !$0 { publishErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(publishErrorMessage ?? "")
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            // Only continue into the pending Share/Add-to-Library action if
            // sign-in actually succeeded — same reasoning as
            // `RecipeDetailView.shareTapped()`'s identical `onDismiss:`.
            if accountSession.isSignedIn, let pendingCardAction {
                switch pendingCardAction {
                case .share(let recipe): shareTargetRecipe = recipe
                case .publish(let recipe): publishTargetRecipe = recipe
                }
            }
            pendingCardAction = nil
        }) {
            AccountSignInView()
        }
        .onChange(of: section) { _, newValue in
            if newValue == .shared {
                Task { await loadSharedRecipes() }
            } else if newValue == .library {
                Task { await loadMasterLibrary() }
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
            masterLibraryRecipes = []
            savedLibraryEntryIDs = []
            masterLibraryLoadError = nil
            if accountSession.isSignedIn {
                if section == .shared {
                    Task { await loadSharedRecipes() }
                } else if section == .library {
                    Task { await loadMasterLibrary() }
                }
            }
        }
        .onChange(of: accountSession.isSignedIn) { _, isSignedIn in
            if !isSignedIn {
                // Sign-out: drop stale rows immediately. `sharedSectionContent`
                // already renders the "Sign In to See Shared Recipes" state
                // whenever `!accountSession.isSignedIn`, so clearing here is
                // enough to avoid a stale list ever being visible — no
                // separate signed-out state needed beyond that existing check.
                // The master library has no equivalent signed-out state
                // (bundled library recipes above it render regardless), so
                // it's just cleared to empty, not re-rendered as anything.
                sharedRecipes = []
                savedShareIDs = []
                sharedLoadError = nil
                isLoadingShared = false
                masterLibraryRecipes = []
                savedLibraryEntryIDs = []
                masterLibraryLoadError = nil
                isLoadingMasterLibrary = false
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
                sharedRecipeCard(entry)
            }
        }
    }

    /// A photo card matching `recipeCard`/`masterLibraryCard`'s own
    /// formatting (see either's doc comment) and, same as every other
    /// recipe card on this screen, tappable to preview it before saving —
    /// direct user report that this used to be a plain `HStack` row where
    /// the untargeted "Save to My Recipes" `Button` (no `.buttonStyle
    /// (.plain)`) ended up as the row's only tap target under the hood, so
    /// tapping *anywhere* in the row — not just that button's own text —
    /// immediately saved it, with no way to preview it first. Opens
    /// `SharedRecipeDetailView` (the "Shared" counterpart to
    /// `LibraryRecipeDetailView` — see that type's own doc comment for why
    /// a read-only detail view built off the wire entry, not
    /// `RecipeDetailView`, which needs an already-persisted `Recipe`);
    /// "Save to My Recipes" is now its own explicit, separately-tappable
    /// button, both here (`.buttonStyle(.plain)`, unlike before) and in
    /// that detail view's toolbar.
    @ViewBuilder
    private func sharedRecipeCard(_ entry: SharedRecipeEntry) -> some View {
        let isSaved = savedShareIDs.contains(entry.id)
        SharedEntryCardContent(entry: entry)
            .background {
                NavigationLink("") {
                    SharedRecipeDetailView(entry: entry, isSaved: isSaved) {
                        saveSharedRecipe(entry)
                    }
                }
                .opacity(0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if isSaved {
                        CircularIconButton(systemImage: "checkmark.circle.fill", tint: .brandSage) {}
                            .allowsHitTesting(false)
                            .accessibilityLabel("Saved to My Recipes")
                    } else {
                        CircularIconButton(systemImage: "square.and.arrow.down", tint: .white) {
                            saveSharedRecipe(entry)
                        }
                        .accessibilityLabel("Save to My Recipes")
                    }
                }
                .padding(8)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
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
    /// `RecipeSource.shared`'s doc comment), so this creates one instead.
    /// The actual construction lives in `SharedRecipeEntry.makeLocalRecipe()`
    /// (`PersonalLibrarySyncService.swift`) — factored out so
    /// `GroupSharedMealPlanView`'s own "Add to your Recipes too?" prompt can
    /// build the exact same local copy without duplicating it a second
    /// time; see that method's own doc comment for the full
    /// photo/sourceURL/backend-id reasoning, which applies verbatim here.
    private func saveSharedRecipe(_ entry: SharedRecipeEntry) {
        modelContext.insert(entry.makeLocalRecipe())
        savedShareIDs.insert(entry.id)
    }

    // MARK: Master library section

    /// The community-published recipes appended below the bundled `.library`
    /// grid in the "Library" segment — same "no local mirror, live fetch"
    /// reasoning as `sharedSectionContent`, just requiring sign-in silently
    /// rather than showing its own "Sign In" prompt (the bundled recipes
    /// above render fine either way, so this section just contributes
    /// nothing extra while signed out instead of interrupting the segment
    /// with a second sign-in call to action).
    @ViewBuilder
    private var masterLibrarySectionContent: some View {
        if accountSession.isSignedIn {
            if isLoadingMasterLibrary {
                ProgressView()
            } else if let masterLibraryLoadError {
                Text(masterLibraryLoadError).font(.brandCaption).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadMasterLibrary() } }
                    .font(.brandCaption)
            } else {
                ForEach(masterLibraryRecipes) { entry in
                    masterLibraryCard(entry)
                }
            }
        }
    }

    /// A photo card matching `recipeCard`'s own formatting exactly (same
    /// `LibraryEntryCardContent`/`RecipeCardContent` layout: photo on top,
    /// title + meta row below) and, same as every other recipe card on this
    /// screen, tappable to open a detail view — direct user report that this
    /// used to be a plain, smaller `HStack` row with no way to view the
    /// recipe at all before saving it, formatted nothing like the bundled
    /// `.library` cards right above it or "My Recipes." Since this entry
    /// hasn't been saved as a local `Recipe` yet (see `saveLibraryEntry`),
    /// it opens `LibraryRecipeDetailView` — a read-only detail screen built
    /// straight off the wire `LibraryRecipeEntry` — rather than the
    /// `Recipe`-`@Bindable` `RecipeDetailView` every other card uses, which
    /// has no path that doesn't already assume a persisted local recipe.
    @ViewBuilder
    private func masterLibraryCard(_ entry: LibraryRecipeEntry) -> some View {
        let isSaved = savedLibraryEntryIDs.contains(entry.id)
        LibraryEntryCardContent(entry: entry)
            .background {
                // Same "flexible hidden NavigationLink behind the card"
                // pattern as `recipeCard` — see that method's own doc
                // comment for why.
                NavigationLink("") {
                    LibraryRecipeDetailView(entry: entry, isSaved: isSaved) {
                        saveLibraryEntry(entry)
                    }
                }
                .opacity(0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if isSaved {
                        CircularIconButton(systemImage: "checkmark.circle.fill", tint: .brandSage) {}
                            .allowsHitTesting(false)
                            .accessibilityLabel("Saved to My Recipes")
                    } else {
                        CircularIconButton(systemImage: "square.and.arrow.down", tint: .white) {
                            saveLibraryEntry(entry)
                        }
                        .accessibilityLabel("Save to My Recipes")
                    }
                }
                .padding(8)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
    }

    private func loadMasterLibrary() async {
        isLoadingMasterLibrary = true
        masterLibraryLoadError = nil
        defer { isLoadingMasterLibrary = false }
        do {
            masterLibraryRecipes = try await AccountsAPIClient.getMasterLibrary()
        } catch {
            masterLibraryLoadError = error.localizedDescription
        }
    }

    /// Same "materialize a wire entry into a local, saved `Recipe`" role as
    /// `saveSharedRecipe` above — see `LibraryRecipeEntry.makeLocalRecipe()`'s
    /// own doc comment (`PersonalLibrarySyncService.swift`).
    private func saveLibraryEntry(_ entry: LibraryRecipeEntry) {
        modelContext.insert(entry.makeLocalRecipe())
        savedLibraryEntryIDs.insert(entry.id)
    }

    // MARK: Card actions (Share, Add to Library)
    //
    // Both gate on sign-in the same way `RecipeDetailView.shareTapped()`
    // already does for its own Share button — see `pendingCardAction`'s own
    // doc comment for how the sign-in sheet resumes whichever action was
    // tapped once it succeeds.

    private func shareTapped(_ recipe: Recipe) {
        if accountSession.isSignedIn {
            shareTargetRecipe = recipe
        } else {
            pendingCardAction = .share(recipe)
            showSignIn = true
        }
    }

    private func publishTapped(_ recipe: Recipe) {
        guard !recipe.isPublishedToLibrary else { return }
        if accountSession.isSignedIn {
            publishTargetRecipe = recipe
        } else {
            pendingCardAction = .publish(recipe)
            showSignIn = true
        }
    }

    /// Publishes `recipe` to the master library — direct user request that
    /// the confirmation dialog ask, right at publish time, whether to be
    /// credited or stay anonymous (see `AccountsAPIClient
    /// .publishRecipeToLibrary(id:anonymous:)`'s own doc comment). Creates
    /// this recipe's backend counterpart first if it's never been synced at
    /// all (`recipe.backendRecipeID == nil`) — same lazy-create-then-reuse
    /// pattern as `RecipeSharePickerSheet.ensureBackendRecipeID()`, just not
    /// factored into a shared helper since that one lives in a different
    /// file scoped to its own sheet.
    private func publish(_ recipe: Recipe, anonymous: Bool) {
        publishTargetRecipe = nil
        Task {
            do {
                let backendID: String
                if let existing = recipe.backendRecipeID {
                    backendID = existing
                } else {
                    let created = try await AccountsAPIClient.createRecipe(RecipeLibraryPayload(recipe: recipe))
                    recipe.backendRecipeID = created.id
                    backendID = created.id
                }
                try await AccountsAPIClient.publishRecipeToLibrary(id: backendID, anonymous: anonymous)
                recipe.isPublishedToLibrary = true
            } catch {
                publishErrorMessage = error.localizedDescription
            }
        }
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

    /// A photo card (image on top, title + details below) with floating
    /// buttons over the image: a heart to favorite, a "+" to jump straight
    /// to `QuickAddToPlanSheet`, and — direct user request, only for a
    /// recipe this account actually created (`source == .manual || .imported`;
    /// a bundled `.library` recipe or one saved from someone else's share
    /// isn't this account's to share or publish further, and publishing one
    /// would just 403 against the backend's own owner check — see
    /// `LibraryRecipeEntry.makeLocalRecipe()`'s doc comment) — a share icon
    /// and an "Add to Library" icon. Tapping the rest of the card opens the
    /// recipe — via a `NavigationLink` hidden in the background rather than
    /// wrapping the visible content directly, which is also what keeps
    /// List from drawing its usual chevron disclosure indicator on the row
    /// (that indicator is tied to the row's top-level content literally
    /// being a `NavigationLink`, not to whether tapping it navigates). Every
    /// button is a separate `.overlay` on the *outside* of this whole
    /// stack, not nested inside the link's label — a `Button` nested inside
    /// a `NavigationLink`'s label fires both the button's action and the
    /// navigation on the same tap.
    @ViewBuilder
    private func recipeCard(_ recipe: Recipe) -> some View {
        let canShareOrPublish = recipe.source == .manual || recipe.source == .imported
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
                VStack(spacing: 6) {
                    CircularIconButton(systemImage: "plus", tint: .white) {
                        quickAddRecipe = recipe
                    }
                    if canShareOrPublish {
                        CircularIconButton(systemImage: "square.and.arrow.up", tint: .white) {
                            shareTapped(recipe)
                        }
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    CircularIconButton(
                        systemImage: recipe.isFavorite ? "heart.fill" : "heart",
                        tint: recipe.isFavorite ? .brandTerracotta : .white
                    ) {
                        recipe.isFavorite.toggle()
                    }
                    if canShareOrPublish {
                        CircularIconButton(
                            systemImage: recipe.isPublishedToLibrary ? "books.vertical.fill" : "books.vertical",
                            tint: recipe.isPublishedToLibrary ? .brandSage : .white
                        ) {
                            publishTapped(recipe)
                        }
                        .accessibilityLabel(recipe.isPublishedToLibrary ? "Already in the Library" : "Add to Library")
                    }
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

/// The photo half of `SharedRecipeEntryThumbnail`/`LibraryEntryCardContent`/
/// `LibraryRecipeDetailView`, deliberately much simpler than `RecipeThumbnail`
/// (no remote-URL/bundled-asset cases: an entry that hasn't been saved as a
/// local `Recipe` yet only ever has a decoded photo or nothing) and with no
/// frame baked in, so each caller sizes it for its own layout (a 56pt square
/// row thumbnail, a 150pt-tall card top, a 200pt-tall detail header) — same
/// placeholder look either way (sage tint, a plain fork-and-knife glyph) so
/// one of these with no photo doesn't look broken or different from any
/// other "no photo" recipe elsewhere in this app.
private struct EntryPhoto: View {
    let photoData: Data?

    var body: some View {
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
}

/// A small square photo for one `sharedRecipeRow`.
private struct SharedRecipeEntryThumbnail: View {
    let photoData: Data?

    var body: some View {
        EntryPhoto(photoData: photoData)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The `RecipeCardContent`-equivalent for a master-library entry that
/// hasn't been saved as a local `Recipe` yet — same layout (photo on top,
/// title + meta row below) built off `LibraryRecipeEntry`'s own fields
/// instead of a `Recipe`'s, plus the "Added by ..." caption a saved
/// recipe's own card has no equivalent of. Not folded into
/// `RecipeCardContent` itself: `RecipeThumbnail` only knows how to read a
/// `Recipe`'s photo/asset/remote-URL fields, none of which an unsaved
/// `LibraryRecipeEntry` has — see `masterLibraryCard`'s own doc comment for
/// the fuller "why a near-duplicate, not a shared generic" reasoning.
private struct LibraryEntryCardContent: View {
    let entry: LibraryRecipeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EntryPhoto(photoData: entry.photoData)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if entry.totalMinutes > 0 {
                        Label("\(entry.totalMinutes) min", systemImage: "clock")
                    }
                    Label("serves \(entry.displayServings)", systemImage: "person.2")
                }
                .font(.brandCaption)
                .foregroundStyle(.secondary)
                Text(entry.addedByCaption)
                    .font(.brandCaption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .background(Color.brandCream)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }
}

/// A read-only recipe detail screen for a master-library entry that hasn't
/// been saved as a local `Recipe` yet — `RecipeDetailView` needs a real,
/// persisted `@Bindable Recipe` (its favorite toggle, editor, and share
/// sheet all write straight to one), which an entry nobody has chosen to
/// save doesn't have; this reads the same information straight off the
/// wire `LibraryRecipeEntry` instead. Same content sections, same section
/// layout, and the same fonts as `RecipeDetailView` (photo, tag-style
/// header, summary, meta row, ingredients, instructions, source link) —
/// only the toolbar action differs: no favorite/edit/share (none of those
/// make sense before this is even saved), just "Save to My Recipes,"
/// mirroring the card's own affordance one screen up.
private struct LibraryRecipeDetailView: View {
    let entry: LibraryRecipeEntry
    let onSave: () -> Void

    @State private var isSaved: Bool

    init(entry: LibraryRecipeEntry, isSaved: Bool, onSave: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        _isSaved = State(initialValue: isSaved)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EntryPhoto(photoData: entry.photoData)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(entry.addedByCaption)
                    .font(.brandCaption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    Label("\(entry.displayServings) servings", systemImage: "person.2")
                    if let prep = entry.prepMinutes, prep > 0 {
                        Label("\(prep)m prep", systemImage: "timer")
                    }
                    if let cook = entry.cookMinutes, cook > 0 {
                        Label("\(cook)m cook", systemImage: "flame")
                    }
                }
                .font(.brandSubheadline)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingredients").font(.brandTitle3.bold())
                    ForEach(entry.ingredients) { ingredient in
                        HStack(alignment: .top) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                                .frame(width: 20)
                            Text(ingredient.displayText)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Instructions").font(.brandTitle3.bold())
                    ForEach(Array(entry.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.brandHeadline)
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                            Text(step)
                        }
                    }
                    if entry.instructions.isEmpty {
                        Text("No steps added yet.").foregroundStyle(.secondary)
                    }
                }

                if let sourceURL = entry.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label("View Original Recipe", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.brandSage)
                } else {
                    Button("Save to My Recipes") {
                        isSaved = true
                        onSave()
                    }
                }
            }
        }
    }
}

/// The `LibraryEntryCardContent` counterpart for a "Shared" entry — same
/// layout, same reasoning for why this is a near-duplicate rather than a
/// shared generic (see that type's own doc comment), just reading
/// `SharedRecipeEntry`'s fields (`sharedByCaption` in place of
/// `addedByCaption`) instead.
private struct SharedEntryCardContent: View {
    let entry: SharedRecipeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EntryPhoto(photoData: entry.photoData)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.brandHeadline)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if entry.totalMinutes > 0 {
                        Label("\(entry.totalMinutes) min", systemImage: "clock")
                    }
                    Label("serves \(entry.displayServings)", systemImage: "person.2")
                }
                .font(.brandCaption)
                .foregroundStyle(.secondary)
                Text(entry.sharedByCaption)
                    .font(.brandCaption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .background(Color.brandCream)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.06)))
    }
}

/// The `LibraryRecipeDetailView` counterpart for a "Shared" entry — same
/// read-only layout/reasoning (see that type's own doc comment), just
/// reading `SharedRecipeEntry`'s fields instead.
private struct SharedRecipeDetailView: View {
    let entry: SharedRecipeEntry
    let onSave: () -> Void

    @State private var isSaved: Bool

    init(entry: SharedRecipeEntry, isSaved: Bool, onSave: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        _isSaved = State(initialValue: isSaved)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EntryPhoto(photoData: entry.photoData)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(entry.sharedByCaption)
                    .font(.brandCaption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    Label("\(entry.displayServings) servings", systemImage: "person.2")
                    if let prep = entry.prepMinutes, prep > 0 {
                        Label("\(prep)m prep", systemImage: "timer")
                    }
                    if let cook = entry.cookMinutes, cook > 0 {
                        Label("\(cook)m cook", systemImage: "flame")
                    }
                }
                .font(.brandSubheadline)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingredients").font(.brandTitle3.bold())
                    ForEach(entry.ingredients) { ingredient in
                        HStack(alignment: .top) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                                .frame(width: 20)
                            Text(ingredient.displayText)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Instructions").font(.brandTitle3.bold())
                    ForEach(Array(entry.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.brandHeadline)
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                            Text(step)
                        }
                    }
                    if entry.instructions.isEmpty {
                        Text("No steps added yet.").foregroundStyle(.secondary)
                    }
                }

                if let sourceURL = entry.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label("View Original Recipe", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.brandSage)
                } else {
                    Button("Save to My Recipes") {
                        isSaved = true
                        onSave()
                    }
                }
            }
        }
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
