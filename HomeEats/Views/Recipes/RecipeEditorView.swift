import SwiftUI
import SwiftData

/// Manual recipe entry per the spec: title, ingredients, instructions.
/// Ingredients and steps are typed one-per-line, which keeps the form simple
/// while still giving `IngredientLineParser` enough structure to auto-sort
/// them into the grocery list later.
struct RecipeEditorView: View {
    var existing: Recipe?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var title: String
    @State private var summary: String
    @State private var servings: Int
    @State private var prepMinutes: Int
    @State private var cookMinutes: Int
    @State private var tagsText: String
    @State private var ingredientsText: String
    @State private var instructionsText: String

    init(existing: Recipe? = nil) {
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _summary = State(initialValue: existing?.summary ?? "")
        _servings = State(initialValue: existing?.servings ?? 4)
        _prepMinutes = State(initialValue: existing?.prepMinutes ?? 0)
        _cookMinutes = State(initialValue: existing?.cookMinutes ?? 0)
        _tagsText = State(initialValue: (existing?.tags ?? []).joined(separator: ", "))
        _ingredientsText = State(initialValue: (existing?.ingredients ?? []).map(\.displayText).joined(separator: "\n"))
        _instructionsText = State(initialValue: (existing?.instructions ?? []).joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe") {
                    TextField("Title", text: $title)
                    TextField("Short description (optional)", text: $summary)
                }
                Section("Details") {
                    Stepper("Servings: \(servings)", value: $servings, in: 1...20)
                    Stepper("Prep: \(prepMinutes) min", value: $prepMinutes, in: 0...240, step: 5)
                    Stepper("Cook: \(cookMinutes) min", value: $cookMinutes, in: 0...480, step: 5)
                    TextField("Tags, comma separated", text: $tagsText)
                }
                Section {
                    TextEditor(text: $ingredientsText)
                        .frame(minHeight: 140)
                } header: {
                    Text("Ingredients")
                } footer: {
                    Text("One ingredient per line, e.g. \"2 cups flour\" or \"1 tsp salt\".")
                }
                Section {
                    TextEditor(text: $instructionsText)
                        .frame(minHeight: 160)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("One step per line.")
                }
            }
            .navigationTitle(existing == nil ? "New Recipe" : "Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let recipe = existing ?? Recipe(title: title, createdByMemberID: activeUserSession.activeMemberID)
        recipe.title = title.trimmingCharacters(in: .whitespaces)
        recipe.summary = summary.isEmpty ? nil : summary
        recipe.servings = servings
        recipe.prepMinutes = prepMinutes
        recipe.cookMinutes = cookMinutes
        recipe.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        recipe.ingredients = ingredientsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(IngredientLineParser.parse)
        recipe.instructions = instructionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if existing == nil {
            modelContext.insert(recipe)
        }
        dismiss()
    }
}
