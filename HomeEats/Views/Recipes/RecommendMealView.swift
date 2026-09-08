import SwiftUI
import SwiftData

/// "What can I make with X, Y, Z" — or, with nothing typed in, "just
/// suggest something" — backed by `ClaudeRecipeService`. Each suggestion
/// can be added straight to My Recipes with one tap.
struct RecommendMealView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var ingredientsText = ""
    @State private var isLoading = false
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
                }
                Section {
                    Button {
                        Task { await fetchSuggestions() }
                    } label: {
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("Get Recipe Ideas")
                        }
                    }
                    .disabled(isLoading || !ClaudeRecipeService.isConfigured)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if !suggestions.isEmpty {
                    Section("Ideas") {
                        ForEach(suggestions) { draft in
                            SuggestionRow(
                                draft: draft,
                                isAdded: addedTitles.contains(draft.title),
                                onAdd: { add(draft) }
                            )
                        }
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
        let ingredients = ingredientsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            suggestions = try await ClaudeRecipeService.recommendMeals(ingredients: ingredients)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ draft: RecipeDraft) {
        let recipe = draft.makeRecipe(createdByMemberID: activeUserSession.activeMemberID)
        modelContext.insert(recipe)
        addedTitles.insert(draft.title)
    }
}

private struct SuggestionRow: View {
    let draft: RecipeDraft
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
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

            Button {
                onAdd()
            } label: {
                Label(isAdded ? "Added" : "Add to My Recipes", systemImage: isAdded ? "checkmark" : "plus")
            }
            .buttonStyle(.bordered)
            .disabled(isAdded)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
