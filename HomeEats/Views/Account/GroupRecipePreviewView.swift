import SwiftUI
import SwiftData
import UIKit

/// Read-only preview of a group meal's recipe, for the case a decided or
/// suggested meal's `recipeID` names a recipe the viewer doesn't have saved
/// locally yet. Reached by tapping a recipe row in `GroupSharedMealPlanView`
/// — direct user request ("why aren't we able to click on it to go into the
/// recipe") — via `GroupPlanRecipeLink`, which only ever falls back to this
/// view when the viewer has no local `Recipe` matching this `recipeID`
/// already (see that type's own doc comment): a `GroupPlannedMeal`/
/// `GroupMealSuggestion.recipeID` just as often names another group
/// member's recipe as the viewer's own, so this fetches it straight from
/// the backend (`GET /recipe-library/:id`, via `AccountsAPIClient
/// .getRecipe(id:)`) rather than requiring it be saved into the local
/// library first.
///
/// "Save to My Recipes" here materializes the fetched `RemoteRecipe` into a
/// local `Recipe` — the exact same path `RecipesHomeView.saveSharedRecipe`
/// already uses for a recipe shared directly with the viewer (see that
/// function's own doc comment); this is just a second call site reached via
/// a group meal instead of the Recipes tab's "Shared" section.
struct GroupRecipePreviewView: View {
    let recipeID: String
    /// Shown as the navigation title / in place of the recipe's own title
    /// while it's still loading — `GroupPlannedMeal`/`GroupMealSuggestion
    /// .cachedRecipeTitle`, already resolved by `GroupSyncService
    /// .resolveRecipeTitle` during the last pull, so the screen doesn't have
    /// to sit on a blank title bar for the length of this view's own fetch.
    let cachedTitle: String?

    @Environment(\.modelContext) private var modelContext
    @State private var recipe: RemoteRecipe?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var didSave = false

    var body: some View {
        Group {
            if let recipe {
                content(for: recipe)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Couldn't Load Recipe",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "This recipe may no longer be available.")
                )
            }
        }
        .navigationTitle(recipe?.title ?? cachedTitle ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func content(for recipe: RemoteRecipe) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photo(for: recipe)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(recipe.title).font(.brandTitle2.bold())

                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }

                metaRow(recipe)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingredients").font(.brandTitle3.bold())
                    ForEach(recipe.ingredients) { ingredient in
                        // Same formatter the local `RecipeIngredientEntry
                        // .displayText` uses, called directly on the
                        // remote (name, quantity, unit) triple — no reason
                        // to duplicate the fraction-formatting logic just
                        // because this ingredient never became a local
                        // model.
                        Text(
                            RecipeIngredientEntry.formattedLine(
                                quantity: ingredient.quantity, unit: ingredient.unit,
                                name: ingredient.name.titleCasedForDisplay
                            )
                        )
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

                if let url = SafeWebLink.url(from: recipe.sourceURL) {
                    Link(destination: url) {
                        Label("View Original Recipe", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Save to My Recipes") { save(recipe) }
                }
            }
        }
    }

    /// Same priority order as the local `RecipeThumbnail` — a user-picked
    /// photo, then a remote image URL (an imported recipe's page-supplied
    /// photo), then a bundled asset (a `.library` recipe's own art), then a
    /// plain placeholder — duplicated rather than reused directly since
    /// `RecipeThumbnail` takes a local `Recipe`, not a `RemoteRecipe`, and
    /// building a throwaway local model just to satisfy that type isn't
    /// worth it for one small, easily-mirrored branch. Direct fix for a
    /// real user report ("I thought we fixed the recipes so that the
    /// pictures correctly show up") — before `RemoteRecipe.imageName`
    /// existed at all, this view had nothing to fall back to but
    /// `photoData`, so any recipe whose photo lived in `imageName` (every
    /// imported or bundled-library recipe, as opposed to one with a
    /// directly user-captured photo) showed nothing here.
    @ViewBuilder
    private func photo(for recipe: RemoteRecipe) -> some View {
        if let photoData = recipe.photoData, let uiImage = UIImage(data: photoData) {
            Image(uiImage: uiImage).resizable().scaledToFill()
        } else if let imageName = recipe.imageName, imageName.lowercased().hasPrefix("http"), let url = RecipeImageProxy.url(for: imageName) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    recipePlaceholder
                }
            }
        } else if let imageName = recipe.imageName, UIImage(named: imageName) != nil {
            Image(imageName).resizable().scaledToFill()
        } else {
            recipePlaceholder
        }
    }

    private var recipePlaceholder: some View {
        ZStack {
            Color.brandSage.opacity(0.15)
            Image(systemName: "fork.knife")
                .foregroundStyle(Color.brandSage)
                .font(.brandTitle)
        }
    }

    private func metaRow(_ recipe: RemoteRecipe) -> some View {
        HStack(spacing: 16) {
            if let servings = recipe.servings {
                Label("\(servings) servings", systemImage: "person.2")
            }
            if let prepMinutes = recipe.prepMinutes {
                Label("\(prepMinutes) min prep", systemImage: "clock")
            }
            if let cookMinutes = recipe.cookMinutes {
                Label("\(cookMinutes) min cook", systemImage: "flame")
            }
        }
        .font(.brandCaption)
        .foregroundStyle(.secondary)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recipe = try await AccountsAPIClient.getRecipe(id: recipeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Same "materialize into a local Recipe, tagged with the backend id it
    /// came from" path as `RecipesHomeView.saveSharedRecipe` — see that
    /// function's own doc comment for the full reasoning, including why
    /// `backendRecipeID` matters (it's what lets a later view of this same
    /// meal skip straight to the now-local copy via `GroupPlanRecipeLink`
    /// instead of coming back through this fetch-from-backend path again).
    private func save(_ recipe: RemoteRecipe) {
        let local = Recipe(
            title: recipe.title,
            source: .shared,
            summary: recipe.summary,
            instructions: recipe.instructions,
            ingredients: recipe.ingredients.map {
                RecipeIngredientEntry(name: $0.name, quantity: $0.quantity, unit: $0.unit)
            },
            servings: recipe.servings ?? 4,
            prepMinutes: recipe.prepMinutes ?? 0,
            cookMinutes: recipe.cookMinutes ?? 0,
            tags: ["Shared"],
            photoData: recipe.photoData,
            backendRecipeID: recipe.id
        )
        modelContext.insert(local)
        didSave = true
    }
}
