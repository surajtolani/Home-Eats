import SwiftUI
import SwiftData

/// Paste-a-link recipe import. Fetches the page and reads its schema.org
/// JSON-LD recipe data; if a site doesn't publish that, the user is offered
/// a shortcut into the manual editor instead of a dead end.
struct RecipeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Read-only, purely to back `duplicateMatch` below.
    @Query private var allRecipes: [Recipe]

    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var importedRecipe: Recipe?
    /// Backs the "Add Anyway?" confirmation dialog — see `duplicateMatch`'s
    /// own doc comment.
    @State private var showDuplicateConfirm = false

    /// Direct user request: "Recipes... should not be able to be added
    /// twice." Matches by `sourceURL` first — the same page imported
    /// again, exact URL and all, is unambiguously the same recipe — then
    /// falls back to title, same as `RecipeEditorView.duplicateMatch`; see
    /// `RecipeDuplicateChecker`'s own doc comment for the full rule.
    private var duplicateMatch: Recipe? {
        guard let importedRecipe else { return nil }
        return RecipeDuplicateChecker.existingMatch(
            title: importedRecipe.title,
            sourceURL: importedRecipe.sourceURL,
            in: allRecipes
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a recipe URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("Works best with recipe blogs and cooking sites.")
                    }
                }

                if let importedRecipe {
                    Section("Preview") {
                        Text(importedRecipe.title).font(.brandHeadline)
                        Text("\(importedRecipe.ingredients.count) ingredients • \(importedRecipe.instructions.count) steps")
                            .font(.brandCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if importedRecipe != nil {
                        Button("Save") { attemptSaveImported() }
                    } else {
                        Button {
                            Task { await fetchPreview() }
                        } label: {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Fetch")
                            }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                    }
                }
            }
            .alert(
                "Already in Your Recipes",
                isPresented: $showDuplicateConfirm,
                presenting: duplicateMatch
            ) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Add Anyway") { saveImported() }
            } message: { match in
                Text("You already have a recipe called \"\(match.title)\". Add another one with the same name?")
            }
        }
    }

    private func fetchPreview() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            importedRecipe = try await RecipeImportService.importRecipe(from: urlText)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Something went wrong importing that link."
        }
    }

    private func attemptSaveImported() {
        if duplicateMatch != nil {
            showDuplicateConfirm = true
        } else {
            saveImported()
        }
    }

    private func saveImported() {
        guard let importedRecipe else { return }
        modelContext.insert(importedRecipe)
        dismiss()
    }
}
