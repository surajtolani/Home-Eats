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
    /// Set when this view is opened from `RecipesHomeView`'s "From the Web"
    /// search results (`RecipeWebSearchService`/`webResultCard`) instead of
    /// the plain "Import from URL" menu item — the URL is already known, so
    /// this pre-fills the field and fetches the preview immediately (see
    /// `body`'s own `.task`) instead of making the user paste the same link
    /// right back in.
    var initialURL: String? = nil
    /// Direct user request: every recipe needs at least one meal type and
    /// one cuisine before it can be saved — same requirement, same
    /// `RecipeTaxonomySheet`, as `RecipeEditorView`'s own (see that type's
    /// own doc comment on `taxonomySheetPendingSave` for the exact
    /// tap-Save-while-incomplete-opens-the-required-sheet flow this
    /// mirrors). `RecipeImportService`/`SchemaOrgRecipeParser` don't read
    /// any course/cuisine data off the source page (most sites don't
    /// publish it in a structured way worth trusting), so this always
    /// starts empty and relies on `RecipeTaxonomySheet`'s own title/
    /// ingredient-based cuisine guess instead.
    @State private var selectedMealCourses: Set<String> = []
    @State private var selectedCuisines: Set<String> = []
    @State private var showTaxonomySheet = false
    @State private var taxonomySheetPendingSave = false

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

    private var taxonomySummary: String {
        let parts = [
            selectedMealCourses.sorted().joined(separator: ", "),
            selectedCuisines.sorted().joined(separator: ", "),
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " · ")
    }

    private var taxonomyRow: some View {
        Button {
            taxonomySheetPendingSave = false
            showTaxonomySheet = true
        } label: {
            HStack {
                Text("Meal Type & Cuisine")
                    .foregroundStyle(.primary)
                Spacer()
                Text(taxonomySummary)
                    .foregroundStyle(taxonomySummary == "Not set" ? .red : .secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
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
                        taxonomyRow
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
                        Button("Save") {
                            // Same required-taxonomy gate as
                            // `RecipeEditorView`'s own Save button — see
                            // this view's `taxonomySheetPendingSave` doc
                            // comment.
                            if selectedMealCourses.isEmpty || selectedCuisines.isEmpty {
                                taxonomySheetPendingSave = true
                                showTaxonomySheet = true
                            } else {
                                attemptSaveImported()
                            }
                        }
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
            .sheet(isPresented: $showTaxonomySheet) {
                RecipeTaxonomySheet(
                    selectedCourses: $selectedMealCourses,
                    selectedCuisines: $selectedCuisines,
                    title: importedRecipe?.title ?? "",
                    ingredientNames: (importedRecipe?.ingredients ?? []).map(\.name),
                    onRequirementMet: {
                        guard taxonomySheetPendingSave else { return }
                        taxonomySheetPendingSave = false
                        attemptSaveImported()
                    }
                )
            }
        }
        .task {
            guard let initialURL, importedRecipe == nil else { return }
            urlText = initialURL
            await fetchPreview()
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
        importedRecipe.mealCourses = MealCourse.allCases.map(\.rawValue).filter(selectedMealCourses.contains)
        importedRecipe.cuisines = CuisineType.allCases.map(\.rawValue).filter(selectedCuisines.contains)
        modelContext.insert(importedRecipe)
        dismiss()
    }
}
