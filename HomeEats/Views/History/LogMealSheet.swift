import SwiftUI
import SwiftData

/// Confirms that a planned meal actually happened and records how it went.
/// This is the bridge between "planned" (`PlannedMeal`) and "actually made"
/// (`MealHistoryEntry`), which is what the recommendation engine learns from.
struct LogMealSheet: View {
    let meal: PlannedMeal

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var rating: MealRating = .liked
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(meal.displayTitle)
                        .font(.headline)
                }
                Section("How was it?") {
                    Picker("Rating", selection: $rating) {
                        Text("😖 Not a hit").tag(MealRating.disliked)
                        Text("🙂 It was fine").tag(MealRating.neutral)
                        Text("😋 Loved it").tag(MealRating.liked)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Notes (optional)") {
                    TextEditor(text: $notes).frame(minHeight: 80)
                }
            }
            .navigationTitle("Log Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let entry = MealHistoryEntry(
            date: meal.date,
            recipeID: meal.recipe?.id,
            restaurantID: meal.restaurant?.id,
            rating: rating,
            madeByMemberID: activeUserSession.activeMemberID,
            notes: notes.isEmpty ? nil : notes
        )
        modelContext.insert(entry)
        dismiss()
    }
}
