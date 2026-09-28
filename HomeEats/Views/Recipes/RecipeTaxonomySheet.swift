import SwiftUI

/// The pop-up sheet for tagging a recipe with its course(s) and cuisine(s)
/// — both multi-select, since a dish can genuinely be more than one of
/// either (e.g. "Snack" + "Seasonal", or a fusion dish with two cuisines).
/// Presented from every recipe-creation flow (`RecipeEditorView`,
/// `RecipeAIImportView`, `RecipeImportView`, `RecommendMealView`) and from
/// `RecipesHomeView`'s "complete your recipes" gate for older recipes saved
/// before this existed.
///
/// **Mandatory by default** — direct user request: every recipe needs at
/// least one meal type and one cuisine, not just an optional tag. `Done` is
/// disabled until both `selectedCourses` and `selectedCuisines` have at
/// least one entry, and the sheet can't be swiped away to skip that — see
/// `isRequired`'s own doc comment for the one case that opts out.
struct RecipeTaxonomySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCourses: Set<String>
    @Binding var selectedCuisines: Set<String>
    /// Read once, on first appearance, to auto-suggest a cuisine — see
    /// `didAutoGuess` below.
    let title: String
    let ingredientNames: [String]
    /// `false` only for `RecipesHomeView`'s own Filter sheet, which reuses
    /// this exact picker to narrow the list down rather than to tag one
    /// recipe — there, an empty selection is a completely valid "no
    /// filter," not an incomplete recipe, so neither the swipe-to-dismiss
    /// block nor the disabled-until-non-empty `Done` button apply.
    var isRequired: Bool = true
    /// Called right after a required sheet's `Done` actually completes
    /// (both sets non-empty) — the caller's cue to proceed with whatever
    /// was waiting on this (saving a new recipe, advancing past one more
    /// recipe in the completion gate). Not called when `isRequired` is
    /// `false`, or when this sheet is just being reopened to edit an
    /// already-complete recipe's tags (nothing was "waiting" on that).
    var onRequirementMet: (() -> Void)? = nil

    /// Guards the auto-guess so it only ever runs once per sheet
    /// presentation, not every time SwiftUI re-evaluates `onAppear`.
    @State private var didAutoGuess = false

    private var meetsRequirement: Bool {
        !selectedCourses.isEmpty && !selectedCuisines.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text(isRequired ? "Select all that apply. At least one is required." : "Select all that apply.")
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
                    Text(
                        isRequired
                            ? "Auto-suggested from the title and ingredients — adjust or select more if it's a mix. At least one is required."
                            : "Auto-suggested from the title and ingredients — adjust or select more if it's a mix."
                    )
                }
            }
            .navigationTitle("Meal Type & Cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        if isRequired && meetsRequirement {
                            onRequirementMet?()
                        }
                    }
                    .disabled(isRequired && !meetsRequirement)
                }
            }
            // A required tag can't be skipped by swiping the sheet away —
            // matches `Done` being disabled until it's actually satisfied.
            .interactiveDismissDisabled(isRequired)
            .onAppear {
                guard !didAutoGuess else { return }
                didAutoGuess = true
                guard selectedCuisines.isEmpty else { return }
                for guess in CuisineType.guess(title: title, ingredientNames: ingredientNames) {
                    selectedCuisines.insert(guess.rawValue)
                }
            }
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
