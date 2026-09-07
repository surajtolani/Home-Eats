import SwiftUI
import SwiftData

/// The guided flow launched by the weekly planning notification (or the
/// "Start Planning" button — see `CalendarPlanView`'s toolbar). Walks through
/// each day in the upcoming week that doesn't have dinner sorted yet —
/// dinner being the meal a weekly planning session is really about — one at
/// a time, so planning takes a minute, not a browsing session.
/// Breakfast/lunch/other stay reachable per day for anyone who wants to plan
/// those too.
struct PlanningReminderFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query private var allPlannedMeals: [PlannedMeal]

    /// Days the user tapped "Skip for now" on *this session* — kept
    /// separately from "decided" so skipping doesn't require any index
    /// bookkeeping. We always just show the first date that's neither
    /// decided nor skipped; once a day gets a decided dinner it drops out of
    /// `undecidedDinnerDates` on its own, no manual "advance" step needed.
    @State private var skippedDates: Set<Date> = []
    @State private var showRecipePicker = false
    @State private var showRestaurantPicker = false

    private var calendar: Calendar { Calendar.current }

    private var upcomingDates: [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private func dinnerIsDecided(on date: Date) -> Bool {
        allPlannedMeals.contains { $0.date.isSameDay(as: date) && $0.slot == .dinner }
    }

    private var undecidedDinnerDates: [Date] {
        upcomingDates.filter { !dinnerIsDecided(on: $0) }
    }

    private var remainingDates: [Date] {
        undecidedDinnerDates.filter { date in !skippedDates.contains { $0.isSameDay(as: date) } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let date = remainingDates.first {
                    dayCard(for: date)
                } else {
                    allSetView
                }
            }
            .background(Color.brandCream.ignoresSafeArea())
            .navigationTitle("Plan the Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var allSetView: some View {
        ContentUnavailableView(
            "You're All Set!",
            systemImage: "checkmark.circle.fill",
            description: Text("Every day this week has dinner planned. Nice work.")
        )
    }

    private func dayCard(for date: Date) -> some View {
        VStack(spacing: 20) {
            ProgressView(
                value: Double(undecidedDinnerDates.count - remainingDates.count + 1),
                total: Double(max(undecidedDinnerDates.count, 1))
            )
            .padding(.horizontal)

            VStack(spacing: 4) {
                Text(date.formatted(Date.weekdayFull))
                    .font(.brandLargeTitle.bold())
                Text(date.formatted(Date.monthDay))
                    .foregroundStyle(.secondary)
                Text("What's for dinner?")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.top, 24)

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

                NavigationLink {
                    DayDetailView(date: date)
                } label: {
                    Text("Plan breakfast, lunch & more for this day")
                }
                .font(.brandFootnote)
                .padding(.top, 4)

                Button("Skip for now") {
                    skippedDates.insert(date)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet { recipe in
                decideDinner(date: date, recipe: recipe)
            }
        }
        .sheet(isPresented: $showRestaurantPicker) {
            RestaurantPickerSheet { restaurant in
                decideDinner(date: date, restaurant: restaurant)
            }
        }
    }

    private func decideDinner(date: Date, recipe: Recipe? = nil, restaurant: Restaurant? = nil) {
        let meal = PlannedMeal(
            date: date,
            slot: .dinner,
            recipe: recipe,
            restaurant: restaurant,
            decidedByMemberID: activeUserSession.activeMemberID
        )
        modelContext.insert(meal)
    }
}
