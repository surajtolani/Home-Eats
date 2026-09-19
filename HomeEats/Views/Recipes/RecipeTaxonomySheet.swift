import SwiftUI

/// The pop-up sheet for tagging a recipe with its course(s) and cuisine(s)
/// — both multi-select, since a dish can genuinely be more than one of
/// either (e.g. "Snack" + "Seasonal", or a fusion dish with two cuisines).
/// Presented from `RecipeEditorView` when adding or editing a recipe.
struct RecipeTaxonomySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCourses: Set<String>
    @Binding var selectedCuisines: Set<String>
    /// Read once, on first appearance, to auto-suggest a cuisine — see
    /// `didAutoGuess` below.
    let title: String
    let ingredientNames: [String]

    /// Guards the auto-guess so it only ever runs once per sheet
    /// presentation, not every time SwiftUI re-evaluates `onAppear`.
    @State private var didAutoGuess = false

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
                    Text("Select all that apply.")
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
                    Text("Auto-suggested from the title and ingredients — adjust or select more if it's a mix.")
                }
            }
            .navigationTitle("Meal Type & Cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
