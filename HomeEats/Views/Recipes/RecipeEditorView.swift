import SwiftUI
import SwiftData
import PhotosUI

/// Manual recipe entry per the spec: title, ingredients, instructions.
/// Ingredients and steps are typed one-per-line, which keeps the form simple
/// while still giving `IngredientLineParser` enough structure to auto-sort
/// them into the grocery list later.
struct RecipeEditorView: View {
    var existing: Recipe?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    /// Read-only, purely to back `duplicateMatch` below.
    @Query private var allRecipes: [Recipe]

    @State private var title: String
    @State private var summary: String
    @State private var servings: Int
    @State private var prepMinutes: Int
    @State private var cookMinutes: Int
    @State private var tagsText: String
    @State private var ingredientsText: String
    @State private var instructionsText: String
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var selectedMealCourses: Set<String>
    @State private var selectedCuisines: Set<String>
    @State private var showTaxonomySheet = false
    /// Backs the "Add Anyway?" confirmation dialog — see `duplicateMatch`'s
    /// own doc comment.
    @State private var showDuplicateConfirm = false

    /// Direct user request: "Recipes... should not be able to be added
    /// twice." Only meaningful for a brand-new recipe (`existing == nil`)
    /// — editing an existing one obviously keeps its own title. Delegates
    /// to `RecipeDuplicateChecker` — see that type's own doc comment for
    /// the exact matching rule.
    private var duplicateMatch: Recipe? {
        guard existing == nil else { return nil }
        return RecipeDuplicateChecker.existingMatch(title: title, sourceURL: nil, in: allRecipes)
    }

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
        _photoData = State(initialValue: existing?.photoData)
        _selectedMealCourses = State(initialValue: Set(existing?.mealCourses ?? []))
        _selectedCuisines = State(initialValue: Set(existing?.cuisines ?? []))
    }

    private var taxonomySummary: String {
        let parts = [
            selectedMealCourses.sorted().joined(separator: ", "),
            selectedCuisines.sorted().joined(separator: ", "),
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " · ")
    }

    /// Pulled out of `body`'s "Details" section as its own explicitly-typed
    /// property — folded inline, this pushed the surrounding `Form`'s
    /// already-large view-builder expression graph past the type
    /// checker's complexity budget ("unable to type-check this expression
    /// in reasonable time"). Splitting it out gives the checker a much
    /// smaller expression to solve here, independent of everything else in
    /// `body`.
    private var taxonomyRow: some View {
        Button {
            showTaxonomySheet = true
        } label: {
            HStack {
                Text("Meal Type & Cuisine")
                    .foregroundStyle(.primary)
                Spacer()
                Text(taxonomySummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe") {
                    TextField("Title", text: $title)
                    TextField("Short description (optional)", text: $summary)
                }
                Section("Photo") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        if let photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Label("Add a Photo", systemImage: "camera")
                        }
                    }
                }
                Section("Details") {
                    Stepper("Servings: \(servings)", value: $servings, in: 1...20)
                    Stepper("Prep: \(prepMinutes) min", value: $prepMinutes, in: 0...240, step: 5)
                    Stepper("Cook: \(cookMinutes) min", value: $cookMinutes, in: 0...480, step: 5)
                    TextField("Tags, comma separated", text: $tagsText)
                    taxonomyRow
                }
                Section {
                    TextEditor(text: $ingredientsText)
                        .frame(minHeight: 140)
                } header: {
                    Text("Ingredients")
                } footer: {
                    Text("One ingredient per line, e.g. \"2 cups flour\" or \"1 tsp salt\".")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $instructionsText)
                        .frame(minHeight: 160)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("One step per line.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "New Recipe" : "Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { attemptSave() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        photoData = ImageResizing.downsized(data, maxDimension: 800)
                    }
                }
            }
            .alert(
                "Already in Your Recipes",
                isPresented: $showDuplicateConfirm,
                presenting: duplicateMatch
            ) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Add Anyway") { save() }
            } message: { match in
                Text("You already have a recipe called \"\(match.title)\". Add another one with the same name?")
            }
            .sheet(isPresented: $showTaxonomySheet) {
                RecipeTaxonomySheet(
                    selectedCourses: $selectedMealCourses,
                    selectedCuisines: $selectedCuisines,
                    title: title,
                    ingredientNames: ingredientsText.components(separatedBy: .newlines)
                )
            }
        }
    }

    private func attemptSave() {
        if duplicateMatch != nil {
            showDuplicateConfirm = true
        } else {
            save()
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
        recipe.photoData = photoData
        recipe.mealCourses = MealCourse.allCases.map(\.rawValue).filter(selectedMealCourses.contains)
        recipe.cuisines = CuisineType.allCases.map(\.rawValue).filter(selectedCuisines.contains)

        if existing == nil {
            modelContext.insert(recipe)
        }
        dismiss()
    }
}
