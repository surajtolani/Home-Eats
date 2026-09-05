import SwiftUI
import SwiftData

/// The guided flow launched by the weekly planning notification (or the
/// "Start Planning" button). Walks through each not-yet-decided day in the
/// upcoming week one at a time so planning takes a minute, not a browsing
/// session.
struct PlanningReminderFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \DayPlan.date) private var allDayPlans: [DayPlan]

    @State private var index = 0
    @State private var showRecipePicker = false
    @State private var showRestaurantPicker = false

    private var calendar: Calendar { Calendar.current }

    private var upcomingDates: [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// The next 7 days. Guaranteed to have a persisted DayPlan once
    /// `ensureDayPlansExist()` (run from `.task` on appear) has completed.
    private var upcomingDayPlans: [DayPlan] {
        upcomingDates.map { date in
            allDayPlans.first { $0.date.isSameDay(as: date) } ?? DayPlan(date: date)
        }
    }

    private func ensureDayPlansExist() {
        for date in upcomingDates {
            let normalized = DayPlan.normalize(date)
            if !allDayPlans.contains(where: { $0.date.isSameDay(as: normalized) }) {
                modelContext.insert(DayPlan(date: normalized))
            }
        }
    }

    private var undecidedDayPlans: [DayPlan] {
        upcomingDayPlans.filter { !$0.isDecided }
    }

    var body: some View {
        NavigationStack {
            Group {
                if undecidedDayPlans.isEmpty {
                    allSetView
                } else if index < undecidedDayPlans.count {
                    dayCard(for: undecidedDayPlans[index])
                } else {
                    allSetView
                }
            }
            .navigationTitle("Plan the Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                ensureDayPlansExist()
            }
        }
    }

    private var allSetView: some View {
        ContentUnavailableView(
            "You're All Set!",
            systemImage: "checkmark.circle.fill",
            description: Text("Every day this week has a plan. Nice work.")
        )
    }

    private func dayCard(for dayPlan: DayPlan) -> some View {
        VStack(spacing: 20) {
            ProgressView(value: Double(index + 1), total: Double(max(undecidedDayPlans.count, 1)))
                .padding(.horizontal)

            VStack(spacing: 4) {
                Text(dayPlan.date.formatted(Date.weekdayFull))
                    .font(.largeTitle.bold())
                Text(dayPlan.date.formatted(Date.monthDay))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            if !dayPlan.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions so far").font(.subheadline.bold())
                    ForEach(dayPlan.suggestions) { suggestion in
                        Text("• \(suggestion.displayTitle) (\(suggestion.voteCount) vote(s))")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    showRecipePicker = true
                } label: {
                    Label("Cook a Recipe", systemImage: "frying.pan")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showRestaurantPicker = true
                } label: {
                    Label("Eat Out", systemImage: "fork.knife")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Skip for now") {
                    advance()
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet { recipe in
                dayPlan.finalize(recipe: recipe, by: activeUserSession.activeMemberID)
                advance()
            }
        }
        .sheet(isPresented: $showRestaurantPicker) {
            RestaurantPickerSheet { restaurant in
                dayPlan.finalize(restaurant: restaurant, by: activeUserSession.activeMemberID)
                advance()
            }
        }
    }

    private func advance() {
        // Don't just increment `index` blindly: once a day is decided it
        // drops out of `undecidedDayPlans`, so the same index now points at
        // the *next* remaining day already.
        if index >= undecidedDayPlans.count {
            index = max(0, undecidedDayPlans.count - 1)
        }
    }
}
