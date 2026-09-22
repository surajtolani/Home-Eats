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
    @State private var showDuplicates = false
    /// Direct user report: deleting a recipe that was already decided into
    /// a (possibly shared/group) meal plan used to silently leave that
    /// plan entry broken ("Planned"/"by Someone" — see
    /// `CascadeCleanup`'s own doc comment). Set instead of deleting
    /// whenever `CascadeCleanup.isRecipeInAnyPlannedMeal` says the recipe
    /// being swiped away is still in use.
    @State private var deleteBlockedMessage: String?

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
                                    deleteRecipe(recipe)
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
            // Direct user request: "There should be a way to eliminate
            // duplications." See `DuplicateRecipesView`'s own doc comment
            // for what this opens.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDuplicates = true
                } label: {
                    Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                }
                .accessibilityLabel("Find Duplicate Recipes")
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
        .sheet(isPresented: $showDuplicates) {
            DuplicateRecipesView()
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
        .alert(
            "Can't Delete Recipe",
            isPresented: Binding(get: { deleteBlockedMessage != nil }, set: { if !$0 { deleteBlockedMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteBlockedMessage ?? "")
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
        } else if isLoadingShared && sharedRecipes.isEmpty {
            // Only shown when there's truly nothing yet to display — a
            // cache hit (see `loadSharedRecipes`) means `sharedRecipes` is
            // already populated by the time this renders, so the list
            // below shows immediately instead of a spinner, and a
            // background refresh updates it in place.
            ProgressView()
        } else if let sharedLoadError, sharedRecipes.isEmpty {
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

    /// A `MediaTileRow` matching `recipeCard`/`masterLibraryCard`'s own
    /// formatting (see either's doc comment) and, same as every other tile
    /// on this screen, tappable to preview it before saving — direct user
    /// report that this used to be a plain `HStack` row where the
    /// untargeted "Save to My Recipes" `Button` (no `.buttonStyle(.plain)`)
    /// ended up as the row's only tap target under the hood, so tapping
    /// *anywhere* in the row — not just that button's own text —
    /// immediately saved it, with no way to preview it first. Opens
    /// `SharedRecipeDetailView` (the "Shared" counterpart to
    /// `LibraryRecipeDetailView` — see that type's own doc comment for why
    /// a read-only detail view built off the wire entry, not
    /// `RecipeDetailView`, which needs an already-persisted `Recipe`);
    /// "Save to My Recipes" is now the tile's floating accessory badge,
    /// both here and in that detail view's toolbar.
    @ViewBuilder
    private func sharedRecipeCard(_ entry: SharedRecipeEntry) -> some View {
        // `savedShareIDs` alone only covers a save made *this session* —
        // also true if a past session already saved this exact recipe
        // (`Recipe.backendRecipeID == entry.recipeID`), so reopening
        // "Shared" later still shows it as saved rather than offering a
        // save that would now just no-op. Direct user request: "Recipes...
        // should not be able to be added twice."
        let isSaved = savedShareIDs.contains(entry.id)
            || allRecipes.contains { $0.backendRecipeID == entry.recipeID }
        MediaTileRow(
            title: entry.title,
            metaItems: sharedEntryMetaItems(entry),
            thumbnail: { EntryPhoto(photoData: entry.photoData) },
            actions: [
                MediaTileAction(
                    icon: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down",
                    tint: isSaved ? .brandSage : .brandForest,
                    label: isSaved ? "Saved to My Recipes" : "Save to My Recipes",
                    onTap: isSaved ? nil : { saveSharedRecipe(entry) }
                )
            ]
        )
        .background {
            NavigationLink("") {
                SharedRecipeDetailView(entry: entry, isSaved: isSaved) {
                    saveSharedRecipe(entry)
                }
            }
            .opacity(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func sharedEntryMetaItems(_ entry: SharedRecipeEntry) -> [[(icon: String?, text: String)]] {
        var firstRow: [(icon: String?, text: String)] = []
        if entry.totalMinutes > 0 {
            firstRow.append((icon: "clock", text: "\(entry.totalMinutes) min"))
        }
        firstRow.append((icon: "person.2", text: "serves \(entry.displayServings)"))
        return [firstRow, [(icon: "person.2", text: entry.sharedByCaption)]]
    }

    /// Seeds `sharedRecipes` from `LocalDataCache`'s last successful
    /// snapshot before the live fetch even starts (see that type's own doc
    /// comment) — a real list shows up immediately instead of a spinner
    /// that turns into a blank error state if the connection is offline or
    /// slow. A failed live fetch only surfaces `sharedLoadError` (replacing
    /// the section's content — see `sharedSectionContent`) if the cache
    /// seed also came up empty; otherwise the cached list just stays on
    /// screen, silently stale, rather than being yanked away by one failed
    /// refresh.
    private func loadSharedRecipes() async {
        isLoadingShared = true
        sharedLoadError = nil
        if sharedRecipes.isEmpty, let userID = accountSession.currentUser?.id {
            sharedRecipes = LocalDataCache.load([SharedRecipeEntry].self, key: sharedRecipesCacheKey(userID: userID)) ?? []
        }
        let hasNothingToShowYet = sharedRecipes.isEmpty
        defer { isLoadingShared = false }
        do {
            let fetched = try await AccountsAPIClient.getSharedRecipes()
            sharedRecipes = fetched
            if let userID = accountSession.currentUser?.id {
                LocalDataCache.save(fetched, key: sharedRecipesCacheKey(userID: userID))
            }
        } catch {
            if hasNothingToShowYet {
                sharedLoadError = error.localizedDescription
            }
        }
    }

    private func sharedRecipesCacheKey(userID: String) -> String { "shared-recipes-\(userID)" }

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
        savedShareIDs.insert(entry.id)
        // Defensive backstop for `sharedRecipeCard`'s own `isSaved` check
        // above — that already hides this action once a match exists, this
        // just makes sure a stale render/race can't still insert a second
        // copy.
        guard !allRecipes.contains(where: { $0.backendRecipeID == entry.recipeID }) else { return }
        modelContext.insert(entry.makeLocalRecipe())
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
            // Same stale-while-revalidate shape as `sharedSectionContent` —
            // a cache hit (see `loadMasterLibrary`) means `masterLibraryRecipes`
            // is already populated by the time this renders, so the spinner/
            // error states below only ever show when there's truly nothing
            // cached yet.
            if isLoadingMasterLibrary && masterLibraryRecipes.isEmpty {
                ProgressView()
            } else if let masterLibraryLoadError, masterLibraryRecipes.isEmpty {
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

    /// A `MediaTileRow` matching `recipeCard`'s own formatting exactly —
    /// direct user request for one consistent tile format across every
    /// recipe/restaurant/plan tile (see that type's own doc comment) — and,
    /// same as every other tile on this screen, tappable to open a detail
    /// view. Since this entry hasn't been saved as a local `Recipe` yet
    /// (see `saveLibraryEntry`), it opens `LibraryRecipeDetailView` — a
    /// read-only detail screen built straight off the wire
    /// `LibraryRecipeEntry` — rather than the `Recipe`-`@Bindable`
    /// `RecipeDetailView` every other tile uses, which has no path that
    /// doesn't already assume a persisted local recipe.
    @ViewBuilder
    private func masterLibraryCard(_ entry: LibraryRecipeEntry) -> some View {
        // Same "also true across sessions, not just this one" reasoning as
        // `sharedRecipeCard`'s own `isSaved` — see that one's doc comment.
        // `entry.id` already equals `entry.recipeID` (`LibraryRecipeEntry
        // .id`), so this is really the same check as the `backendRecipeID`
        // one below, worded to make that identity explicit rather than
        // relying on it silently.
        let isSaved = savedLibraryEntryIDs.contains(entry.id)
            || allRecipes.contains { $0.backendRecipeID == entry.recipeID }
        MediaTileRow(
            title: entry.title,
            metaItems: libraryEntryMetaItems(entry),
            thumbnail: { EntryPhoto(photoData: entry.photoData) },
            actions: [
                MediaTileAction(
                    icon: isSaved ? "checkmark.circle.fill" : "square.and.arrow.down",
                    tint: isSaved ? .brandSage : .brandForest,
                    label: isSaved ? "Saved to My Recipes" : "Save to My Recipes",
                    onTap: isSaved ? nil : { saveLibraryEntry(entry) }
                )
            ]
        )
        .background {
            // Same "flexible hidden NavigationLink behind the tile"
            // pattern as `recipeCard` — see that method's own doc comment
            // for why.
            NavigationLink("") {
                LibraryRecipeDetailView(entry: entry, isSaved: isSaved) {
                    saveLibraryEntry(entry)
                }
            }
            .opacity(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func libraryEntryMetaItems(_ entry: LibraryRecipeEntry) -> [[(icon: String?, text: String)]] {
        var firstRow: [(icon: String?, text: String)] = []
        if entry.totalMinutes > 0 {
            firstRow.append((icon: "clock", text: "\(entry.totalMinutes) min"))
        }
        firstRow.append((icon: "person.2", text: "serves \(entry.displayServings)"))
        return [firstRow, [(icon: "books.vertical", text: entry.addedByCaption)]]
    }

    /// Same cache-seed-before-live-fetch shape as `loadSharedRecipes()` —
    /// see `LocalDataCache`'s own doc comment.
    private func loadMasterLibrary() async {
        isLoadingMasterLibrary = true
        masterLibraryLoadError = nil
        if masterLibraryRecipes.isEmpty, let userID = accountSession.currentUser?.id {
            masterLibraryRecipes = LocalDataCache.load([LibraryRecipeEntry].self, key: masterLibraryCacheKey(userID: userID)) ?? []
        }
        let hasNothingToShowYet = masterLibraryRecipes.isEmpty
        defer { isLoadingMasterLibrary = false }
        do {
            let fetched = try await AccountsAPIClient.getMasterLibrary()
            masterLibraryRecipes = fetched
            if let userID = accountSession.currentUser?.id {
                LocalDataCache.save(fetched, key: masterLibraryCacheKey(userID: userID))
            }
        } catch {
            if hasNothingToShowYet {
                masterLibraryLoadError = error.localizedDescription
            }
        }
    }

    private func masterLibraryCacheKey(userID: String) -> String { "master-library-\(userID)" }

    /// Same "materialize a wire entry into a local, saved `Recipe`" role as
    /// `saveSharedRecipe` above — see `LibraryRecipeEntry.makeLocalRecipe()`'s
    /// own doc comment (`PersonalLibrarySyncService.swift`).
    private func saveLibraryEntry(_ entry: LibraryRecipeEntry) {
        savedLibraryEntryIDs.insert(entry.id)
        // Same defensive backstop as `saveSharedRecipe` — see its own doc
        // comment.
        guard !allRecipes.contains(where: { $0.backendRecipeID == entry.recipeID }) else { return }
        modelContext.insert(entry.makeLocalRecipe())
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

    /// A `MediaTileRow` — direct user request for one consistent tile
    /// format shared across the Plan/Restaurants/Recipes tabs (see that
    /// type's own doc comment), replacing this card's previous vertical
    /// photo-on-top layout. Every action this card used to float over the
    /// image (favorite, quick-add, share, add-to-library) stays exactly as
    /// tappable as before — `MediaTileRow`'s `actions` row, not a swipe or
    /// `.contextMenu` (a first attempt at this moved the three secondary
    /// actions there; direct, immediate push-back: "shouldn't be moved to
    /// a swipe... should stay in the tile"). Share/"Add to Library" stay
    /// gated to `source == .manual || .imported` (see `publishTapped`'s
    /// own doc comment for why publishing/sharing someone else's original
    /// work isn't offered at all). Tapping the tile opens the recipe via a
    /// `NavigationLink` hidden in the background, same "keeps List's own
    /// chevron from appearing, and keeps a nested Button from also firing
    /// the navigation" reasoning as before.
    @ViewBuilder
    private func recipeCard(_ recipe: Recipe) -> some View {
        MediaTileRow(
            title: recipe.title,
            metaItems: recipeMetaItems(recipe),
            thumbnail: { RecipeThumbnail(recipe: recipe) },
            actions: recipeTileActions(recipe)
        )
        .background {
            NavigationLink("") {
                RecipeDetailView(recipe: recipe)
            }
            .opacity(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func recipeTileActions(_ recipe: Recipe) -> [MediaTileAction] {
        let canShareOrPublish = recipe.source == .manual || recipe.source == .imported
        var actions: [MediaTileAction] = [
            MediaTileAction(icon: "plus.circle.fill", tint: .brandForest, label: "Add to Plan") {
                quickAddRecipe = recipe
            }
        ]
        if canShareOrPublish {
            actions.append(
                MediaTileAction(icon: "square.and.arrow.up", tint: .brandHoney, label: "Share") {
                    shareTapped(recipe)
                }
            )
            actions.append(
                MediaTileAction(
                    icon: recipe.isPublishedToLibrary ? "books.vertical.fill" : "books.vertical",
                    tint: .brandSage,
                    label: recipe.isPublishedToLibrary ? "Already in Library" : "Add to Library",
                    onTap: recipe.isPublishedToLibrary ? nil : { publishTapped(recipe) }
                )
            )
        }
        actions.append(
            MediaTileAction(
                icon: recipe.isFavorite ? "heart.fill" : "heart",
                tint: .brandTerracotta,
                label: recipe.isFavorite ? "Unfavorite" : "Favorite"
            ) {
                recipe.isFavorite.toggle()
            }
        )
        return actions
    }

    /// Deletes a recipe from "My Recipes"/"Favorites" (swipe-to-delete, or
    /// `DuplicateRecipesView`'s bulk cleanup) — blocked outright if it's
    /// still in the local, personal plan (see `CascadeCleanup`'s own doc
    /// comment). For a recipe that's also synced to the backend, this now
    /// *waits* for the backend's own equivalent check — a recipe still
    /// decided into a *group's* shared plan — before committing the local
    /// delete, rather than firing that request in the background and
    /// deleting locally regardless of what it says (the old "immediate,
    /// online-only" behavior, which is exactly how a recipe still in a
    /// group's plan ended up silently deleted out from under it, leaving
    /// that plan entry as a broken "Planned"/"by Someone" row — direct
    /// user report). A genuine connectivity failure (`AccountsAPIError`
    /// case other than `.server`, e.g. offline) still falls back to the
    /// previous offline-tolerant behavior — delete locally now, let the
    /// next opportunistic sync reconcile — since there's no way to know
    /// either way while offline, and blocking every delete just because
    /// the network happens to be down would be its own regression.
    private func deleteRecipe(_ recipe: Recipe) {
        guard !CascadeCleanup.isRecipeInAnyPlannedMeal(recipeID: recipe.id, in: modelContext) else {
            deleteBlockedMessage = "\"\(recipe.title)\" is in your meal plan. Remove it from the plan before deleting it."
            return
        }
        guard let backendRecipeID = recipe.backendRecipeID else {
            CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
            modelContext.delete(recipe)
            return
        }
        Task {
            do {
                try await AccountsAPIClient.deleteRecipe(id: backendRecipeID)
                CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
                modelContext.delete(recipe)
            } catch AccountsAPIError.server(let message) {
                deleteBlockedMessage = message
            } catch {
                CascadeCleanup.removeReferences(toRecipeID: recipe.id, in: modelContext)
                modelContext.delete(recipe)
            }
        }
    }

    /// Direct user request for a recipe tile's exact meta layout: "below
    /// [the title] should be the time, # of people it serves. below that
    /// should be the source (imported, shared by, etc.)." Time+servings
    /// share the first row, source (when there is one) gets its own row
    /// underneath — exactly this order. No separate "favorite" entry here
    /// (an earlier version added one) since the heart action icon in the
    /// tile's icon row already shows favorited state; a text item
    /// repeating it would push a third, unwanted row onto the tile instead
    /// of just source.
    private func recipeMetaItems(_ recipe: Recipe) -> [[(icon: String?, text: String)]] {
        var firstRow: [(icon: String?, text: String)] = []
        if recipe.totalMinutes > 0 {
            firstRow.append((icon: "clock", text: "\(recipe.totalMinutes) min"))
        }
        firstRow.append((icon: "person.2", text: "serves \(recipe.servings)"))

        var items: [[(icon: String?, text: String)]] = [firstRow]
        if recipe.source == .imported {
            items.append([(icon: "link", text: "imported")])
        }
        if recipe.source == .shared {
            items.append([(icon: "person.2", text: recipe.sharedAttributionCaption)])
        }
        return items
    }
}

/// The photo half of `SharedRecipeEntryThumbnail`/`LibraryRecipeDetailView`/
/// `SharedRecipeDetailView`, deliberately much simpler than `RecipeThumbnail`
/// (no remote-URL/bundled-asset cases: an entry that hasn't been saved as a
/// local `Recipe` yet only ever has a decoded photo or nothing) and with no
/// frame baked in, so each caller sizes it for its own layout (a 56pt
/// square row thumbnail, a `mediaTileHeight`-square `MediaTileRow`
/// thumbnail, a 200pt-tall detail header) — same placeholder look either
/// way (sage tint, a plain fork-and-knife glyph) so one of these with no
/// photo doesn't look broken or different from any other "no photo"
/// recipe elsewhere in this app.
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

                if let url = SafeWebLink.url(from: entry.sourceURL) {
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
            ToolbarItem(placement: .topBarTrailing) {
                ReportRecipeButton(recipeID: entry.recipeID)
            }
        }
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

                if let url = SafeWebLink.url(from: entry.sourceURL) {
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
            ToolbarItem(placement: .topBarTrailing) {
                ReportRecipeButton(recipeID: entry.recipeID)
            }
        }
    }
}
