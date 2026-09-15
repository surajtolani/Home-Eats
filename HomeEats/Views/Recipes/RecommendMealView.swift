import SwiftUI
import SwiftData

/// "What can I make with X, Y, Z" — or, with nothing typed in, "just
/// suggest something" — backed by `ClaudeRecipeService`. Each suggestion
/// can be added straight to My Recipes with one tap.
///
/// **Dual-purpose via `onPick`**: opened standalone (from Recipes — `onPick`
/// `nil`), picking a suggestion inserts it straight into My Recipes, same as
/// always. `GroupSharedMealPlanView`'s "Add a Meal" sheet also opens this
/// exact same view, with `onPick` set — there, picking a suggestion hands
/// the draft back to that caller instead (which decides what "planning it
/// for the group" needs to happen first, since an AI-drafted recipe has no
/// backend id yet to reference) and this view just dismisses; nothing here
/// inserts anything in that mode; see `GroupAddMealSheet.handleRecipeDraftPick`.
struct RecommendMealView: View {
    var onPick: ((RecipeDraft) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var ingredientsText = ""
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var suggestions: [RecipeDraft] = []
    @State private var addedTitles: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                if !ClaudeRecipeService.isConfigured {
                    Section {
                        Text("This feature isn't set up yet — see backend/README.md to enable it.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("e.g. chicken thighs, rice, broccoli", text: $ingredientsText, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("What do you have? (optional)")
                } footer: {
                    Text("Leave this blank for general dinner ideas, or list what's in your fridge or pantry, comma separated.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await fetchSuggestions() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Get Recipe Ideas")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoading || !ClaudeRecipeService.isConfigured)
                } footer: {
                    // Direct user report: this feature seemed to "not work."
                    // The backend is a free-tier Render deployment that
                    // spins down after inactivity (see backend/README.md) —
                    // waking it back up, plus a real Claude generation for
                    // several full recipes, can genuinely take a while on a
                    // cold first request. Without this, a long wait with
                    // only a bare spinner reads as broken/hung rather than
                    // "working, just slow this once."
                    if isLoading {
                        Text("This can take up to a minute the first time, while the server wakes up.")
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { draft in
                            NavigationLink {
                                RecipeDraftPreviewView(
                                    draft: draft,
                                    isAdded: addedTitles.contains(draft.title),
                                    isPickMode: onPick != nil,
                                    onAdd: { add(draft) }
                                )
                            } label: {
                                SuggestionRow(draft: draft, isAdded: addedTitles.contains(draft.title))
                            }
                        }
                        // Direct user request: a way to see ideas beyond the
                        // first batch, not just the initial handful. Asks
                        // the backend for a fresh batch that excludes every
                        // title already shown (`excludeTitles`) rather than
                        // risking Claude repeating (or lightly rewording)
                        // one already on screen, and appends rather than
                        // replaces so earlier ideas stay put.
                        Button {
                            Task { await loadMoreSuggestions() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Text("Show More Ideas")
                                }
                                Spacer()
                            }
                        }
                        .disabled(isLoadingMore || !ClaudeRecipeService.isConfigured)
                    } header: {
                        Text("Ideas")
                    } footer: {
                        Text("Tap an idea to see its full ingredients, instructions, and add it from there.")
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Recommend a Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func fetchSuggestions() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            suggestions = try await ClaudeRecipeService.recommendMeals(ingredients: currentIngredients)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Show More Ideas" — a fresh batch appended to what's already showing,
    /// excluding every title already on screen so it's a genuinely new set
    /// rather than a repeat (see `ClaudeRecipeService.recommendMeals`'s own
    /// `excludeTitles` doc comment). The `existingTitles` filter below is a
    /// belt-and-suspenders backstop for the rare case Claude repeats one
    /// anyway despite being asked not to — without it, a repeated title
    /// would collide with `RecipeDraft.id` (`title`, see that type's own
    /// doc comment), which `ForEach` requires to be unique.
    private func loadMoreSuggestions() async {
        errorMessage = nil
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await ClaudeRecipeService.recommendMeals(
                ingredients: currentIngredients,
                excludeTitles: suggestions.map(\.title)
            )
            let existingTitles = Set(suggestions.map(\.title))
            suggestions.append(contentsOf: more.filter { !existingTitles.contains($0.title) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var currentIngredients: [String] {
        ingredientsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func add(_ draft: RecipeDraft) {
        if let onPick {
            onPick(draft)
            dismiss()
            return
        }
        let recipe = draft.makeRecipe(createdByMemberID: activeUserSession.activeMemberID)
        modelContext.insert(recipe)
        addedTitles.insert(draft.title)
    }
}

private struct SuggestionRow: View {
    let draft: RecipeDraft
    let isAdded: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.title).font(.brandHeadline)
                if let summary = draft.summary, !summary.isEmpty {
                    Text(summary).font(.brandCaption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let servings = draft.servings {
                        Label("serves \(servings)", systemImage: "person.2")
                    }
                    let minutes = (draft.prepMinutes ?? 0) + (draft.cookMinutes ?? 0)
                    if minutes > 0 {
                        Label("\(minutes) min", systemImage: "clock")
                    }
                }
                .font(.brandCaption2)
                .foregroundStyle(.secondary)
            }
            if isAdded {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.brandForest)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shown before a suggested idea is committed to My Recipes — the full
/// ingredient list and instructions, same as a saved recipe's own detail
/// page, so there's something real to decide from beyond just the title and
/// one-line summary. `ClaudeRecipeService.recommendMeals` doesn't return a
/// photo for an idea (it's a text suggestion, not a vision lookup, so there
/// is no real photo of the dish to show) — this shows everything that
/// actually exists for it.
private struct RecipeDraftPreviewView: View {
    let draft: RecipeDraft
    let isAdded: Bool
    /// Set when this view is reached via `RecommendMealView`'s `onPick`
    /// mode — see that type's own doc comment. Swaps the button's label
    /// (and skips the "already added" disabled state, which doesn't apply
    /// here: picking always dismisses straight back to the caller) since
    /// this tap means "use this for the meal I'm planning," not "add it to
    /// My Recipes."
    let isPickMode: Bool
    let onAdd: () -> Void

    var body: some View {
        Form {
            Section {
                Text(draft.title).font(.brandTitle2.bold())
                if let summary = draft.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let servings = draft.servings {
                        Label("serves \(servings)", systemImage: "person.2")
                    }
                    let minutes = (draft.prepMinutes ?? 0) + (draft.cookMinutes ?? 0)
                    if minutes > 0 {
                        Label("\(minutes) min", systemImage: "clock")
                    }
                }
                .font(.brandCaption)
                .foregroundStyle(.secondary)
            }

            if !draft.ingredientLines.isEmpty {
                Section("Ingredients") {
                    ForEach(draft.ingredientLines, id: \.self) { line in
                        Text(line)
                    }
                }
            }

            if !draft.instructions.isEmpty {
                Section("Instructions") {
                    ForEach(Array(draft.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
            }

            Section {
                Button {
                    onAdd()
                } label: {
                    HStack {
                        Spacer()
                        Label(
                            isPickMode ? "Use This" : (isAdded ? "Added" : "Add to My Recipes"),
                            systemImage: isPickMode ? "checkmark" : (isAdded ? "checkmark" : "plus")
                        )
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandForest)
                .disabled(!isPickMode && isAdded)
            }
        }
        .navigationTitle(draft.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
