import SwiftUI
import SwiftData

struct RecipeDetailView: View {
    @Bindable var recipe: Recipe

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @State private var showEditor = false
    @State private var showShareSheet = false
    @State private var showSignIn = false
    /// Set right before presenting the sign-in sheet from `shareTapped()`,
    /// so the `onDismiss:` below knows to continue straight into sharing
    /// once sign-in succeeds, rather than just closing back to this screen
    /// having done nothing — see `shareTapped()`'s own doc comment.
    @State private var pendingShareAfterSignIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RecipeThumbnail(recipe: recipe)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                header

                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                metaRow

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingredients").font(.brandTitle3.bold())
                    ForEach(recipe.ingredients) { ingredient in
                        HStack(alignment: .top) {
                            // A plain bullet, not `ingredient.category
                            // .symbolName` (what this used to show) — direct
                            // user report: one icon per broad category
                            // (produce, meat & seafood, ...) reads as a
                            // specific claim about THIS ingredient, and
                            // `GroceryCategory.guess(fromIngredientName:)`'s
                            // one-symbol-per-bucket icons don't hold up to
                            // that ("a carrot icon for garlic," "a fish icon
                            // for chicken" — both correctly categorized as
                            // Produce/Meat & Seafood, but the specific icon
                            // reads as flat wrong). A bullet carries no
                            // implied specificity to be wrong about.
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
                    ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.brandHeadline)
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                            Text(step)
                        }
                    }
                    if recipe.instructions.isEmpty {
                        Text("No steps added yet.").foregroundStyle(.secondary)
                    }
                }

                if let sourceURL = recipe.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label("View Original Recipe", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    recipe.isFavorite.toggle()
                } label: {
                    Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                }
                .tint(.brandTerracotta)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shareTapped()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if recipe.source == .library && !recipe.isSavedToCollection {
                    Button("Save") {
                        recipe.isSavedToCollection = true
                    }
                } else {
                    Button("Edit") { showEditor = true }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RecipeEditorView(existing: recipe)
        }
        .sheet(isPresented: $showShareSheet) {
            RecipeSharePickerSheet(recipe: recipe)
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            // Only continue into sharing if sign-in actually succeeded —
            // dismissing without completing it (tapping Cancel) should just
            // land back here having done nothing, not force the share
            // sheet open anyway.
            if pendingShareAfterSignIn && accountSession.isSignedIn {
                showShareSheet = true
            }
            pendingShareAfterSignIn = false
        }) {
            AccountSignInView()
        }
    }

    /// Sharing is one of the few things in this app that requires being
    /// signed in (see `AccountSession`'s doc comment on why almost nothing
    /// else does) — someone tapping Share while signed out is prompted
    /// straight into sign-in rather than the button just failing or being
    /// disabled with no explanation, then dropped straight into the share
    /// picker the moment that succeeds so they don't have to tap Share
    /// again.
    private func shareTapped() {
        if accountSession.isSignedIn {
            showShareSheet = true
        } else {
            pendingShareAfterSignIn = true
            showSignIn = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recipe.tags.isEmpty {
                HStack {
                    ForEach(Array(recipe.tags.enumerated()), id: \.offset) { _, tag in
                        Text(displayTag(tag))
                            .font(.brandCaption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
        }
    }

    /// The literal "Shared"/"Library" tag (see `SharedRecipeEntry
    /// .makeLocalRecipe()`/`LibraryRecipeEntry.makeLocalRecipe()`) reads as
    /// `recipe.sharedAttributionCaption` instead of the bare tag text —
    /// same "who shared it" fix as `RecipeCardContent`'s meta row; every
    /// other tag (a custom one, or "AI" from a photo/notes import) passes
    /// through unchanged. Only the caption's own leading word gets
    /// capitalized to match this chip row's existing style ("Shared by
    /// Priya," not "shared by Priya") — deliberately not `.titleCasedForDisplay`
    /// (`.capitalized`), which would also lowercase the rest of a name
    /// that isn't itself all-lowercase (e.g. "McDonald" -> "Mcdonald").
    private func displayTag(_ tag: String) -> String {
        guard tag == "Shared" || tag == "Library" else { return tag }
        let caption = recipe.sharedAttributionCaption
        guard let first = caption.first else { return caption }
        return first.uppercased() + caption.dropFirst()
    }

    private var metaRow: some View {
        HStack(spacing: 20) {
            Label("\(recipe.servings) servings", systemImage: "person.2")
            if recipe.prepMinutes > 0 {
                Label("\(recipe.prepMinutes)m prep", systemImage: "timer")
            }
            if recipe.cookMinutes > 0 {
                Label("\(recipe.cookMinutes)m cook", systemImage: "flame")
            }
        }
        .font(.brandSubheadline)
        .foregroundStyle(.secondary)
    }
}
