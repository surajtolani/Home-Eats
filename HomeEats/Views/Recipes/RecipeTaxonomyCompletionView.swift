import SwiftUI

/// Walks through every recipe `RecipesHomeView.recipesNeedingTaxonomy`
/// found — saved before meal type/cuisine became mandatory — one at a
/// time, requiring at least one of each before moving to the next. Direct
/// user request: existing recipes need to be brought up to the same
/// standard new ones are held to, not just left alone.
///
/// Deliberately its own inline form rather than presenting
/// `RecipeTaxonomySheet` per recipe (a sheet launched from inside another
/// sheet reads as an odd, flickery stack of modals for what's really one
/// continuous task) — same required-selection rules, same `MealCourse`/
/// `CuisineType` picker rows, just advancing through `recipes` in place
/// instead of dismissing and reopening for each one.
///
/// Can be backed out of early (`Cancel`) without penalty — whatever's
/// already been completed stays completed; whatever's left just means
/// `recipesNeedingTaxonomy` (and so `RecipesHomeView`'s own banner) isn't
/// empty yet, and reappears next time this screen is visited. Not a
/// full-screen, no-way-out block: forcing every recipe to be fixed in one
/// sitting before the rest of the app becomes usable again would trap
/// someone with a large library over something that isn't otherwise
/// urgent — the banner's own persistence (it cannot be dismissed without
/// actually completing this) is what makes the requirement stick instead.
struct RecipeTaxonomyCompletionView: View {
    let recipes: [Recipe]

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0
    @State private var selectedCourses: Set<String> = []
    @State private var selectedCuisines: Set<String> = []

    private var currentRecipe: Recipe? {
        recipes.indices.contains(currentIndex) ? recipes[currentIndex] : nil
    }

    private var isLastRecipe: Bool {
        currentIndex >= recipes.count - 1
    }

    private var canAdvance: Bool {
        !selectedCourses.isEmpty && !selectedCuisines.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let currentRecipe {
                    Form {
                        Section {
                            Text(currentRecipe.title).font(.brandHeadline)
                        } footer: {
                            Text("Recipe \(currentIndex + 1) of \(recipes.count)")
                        }

                        Section {
                            ForEach(MealCourse.allCases) { course in
                                toggleRow(course.rawValue, isSelected: selectedCourses.contains(course.rawValue)) {
                                    if selectedCourses.contains(course.rawValue) {
                                        selectedCourses.remove(course.rawValue)
                                    } else {
                                        selectedCourses.insert(course.rawValue)
                                    }
                                }
                            }
                        } header: {
                            Text("Meal Type")
                        } footer: {
                            Text("Select all that apply. At least one is required.")
                        }

                        Section {
                            ForEach(CuisineType.allCases) { cuisine in
                                toggleRow(cuisine.rawValue, isSelected: selectedCuisines.contains(cuisine.rawValue)) {
                                    if selectedCuisines.contains(cuisine.rawValue) {
                                        selectedCuisines.remove(cuisine.rawValue)
                                    } else {
                                        selectedCuisines.insert(cuisine.rawValue)
                                    }
                                }
                            }
                        } header: {
                            Text("Cuisine")
                        } footer: {
                            Text("Auto-suggested from the title and ingredients — adjust or select more if it's a mix. At least one is required.")
                        }

                        Section {
                            Button {
                                saveCurrentAndAdvance()
                            } label: {
                                Text(isLastRecipe ? "Finish" : "Save & Next")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandForest)
                            .controlSize(.large)
                            .disabled(!canAdvance)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } else {
                    // Reached only if `recipes` was empty to begin with —
                    // `RecipesHomeView` only presents this when
                    // `recipesNeedingTaxonomy` is non-empty, so this is just
                    // a safe fallback, not a real, expected state.
                    ContentUnavailableView(
                        "All Set",
                        systemImage: "checkmark.circle",
                        description: Text("Every recipe already has a meal type and cuisine.")
                    )
                }
            }
            .navigationTitle("Complete Your Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { loadSelectionsForCurrent() }
            .onChange(of: currentIndex) { _, _ in loadSelectionsForCurrent() }
        }
    }

    /// Seeds the pickers from whatever's already set on `currentRecipe`
    /// (partial — e.g. a course chosen but no cuisine — rather than always
    /// starting blank), and auto-guesses a cuisine from the title/
    /// ingredients the same way `RecipeTaxonomySheet` does, but only when
    /// nothing's set yet.
    private func loadSelectionsForCurrent() {
        guard let currentRecipe else { return }
        selectedCourses = Set(currentRecipe.mealCourses)
        selectedCuisines = Set(currentRecipe.cuisines)
        guard selectedCuisines.isEmpty else { return }
        let ingredientNames = currentRecipe.ingredients.map(\.name)
        for guess in CuisineType.guess(title: currentRecipe.title, ingredientNames: ingredientNames) {
            selectedCuisines.insert(guess.rawValue)
        }
    }

    private func saveCurrentAndAdvance() {
        guard let currentRecipe else { return }
        currentRecipe.mealCourses = MealCourse.allCases.map(\.rawValue).filter(selectedCourses.contains)
        currentRecipe.cuisines = CuisineType.allCases.map(\.rawValue).filter(selectedCuisines.contains)
        if isLastRecipe {
            dismiss()
        } else {
            currentIndex += 1
        }
    }

    @ViewBuilder
    private func toggleRow(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
