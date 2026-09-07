import SwiftUI
import SwiftData

/// Adds a recipe straight to a day + meal slot from wherever the recipe is
/// being looked at (the "+" on a Recipes row, say), without navigating to
/// that day in the Plan tab first. Two controls, one button — the point is
/// minimizing taps for the common case, not surfacing every planning option;
/// suggestions/voting and eating out still go through the Plan tab.
struct QuickAddToPlanSheet: View {
    let recipe: Recipe

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var date: Date = Calendar.current.startOfDay(for: .now)
    @State private var slot: MealSlot = .dinner

    var body: some View {
        NavigationStack {
            Form {
                Section(recipe.title) {
                    DatePicker("Day", selection: $date, displayedComponents: .date)
                    Picker("Meal", selection: $slot) {
                        ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                            Label(slot.displayName, systemImage: slot.symbolName).tag(slot)
                        }
                    }
                }
            }
            .navigationTitle("Add to Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addToPlan() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func addToPlan() {
        let meal = PlannedMeal(
            date: PlannedMeal.normalize(date),
            slot: slot,
            recipe: recipe,
            decidedByMemberID: activeUserSession.activeMemberID
        )
        modelContext.insert(meal)
        dismiss()
    }
}
