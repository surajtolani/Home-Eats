import SwiftUI
import SwiftData

/// The Plan tab: a real month calendar (not a single week at a time), so the
/// household can plan several weeks out at a glance. Past days are dimmed
/// since they're done and gone; today is highlighted; tapping any day opens
/// its plan.
struct CalendarPlanView: View {
    @Binding var showPlanningFlow: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayPlan.date) private var allDayPlans: [DayPlan]

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)

    private var calendar: Calendar { Calendar.current }

    private var gridDays: [Date] {
        calendar.gridDays(forMonthContaining: displayedMonth)
    }

    private var isShowingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthHeader
                legend
                weekdayHeaderRow
                monthGrid
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Plan")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ActiveUserMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { goToToday() }
                    .disabled(isShowingCurrentMonth)
            }
        }
        .task(id: displayedMonth) {
            ensureDayPlansExist(for: gridDays)
        }
        .fullScreenCover(isPresented: $showPlanningFlow) {
            PlanningReminderFlowView()
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { changeMonth(by: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.title2.bold())
            Spacer()
            Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: .green, label: "Cooking")
            legendItem(color: .orange, label: "Eating out")
            legendItem(color: .gray, label: "Suggested")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private var weekdayHeaderRow: some View {
        HStack {
            ForEach(calendar.orderedVeryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(gridDays, id: \.self) { day in
                NavigationLink {
                    DayPlanDetailView(dayPlan: dayPlan(for: day))
                } label: {
                    DayCell(
                        date: day,
                        isCurrentMonth: calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isPast: day < calendar.startOfDay(for: .now),
                        dayPlan: dayPlan(for: day)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = calendar.startOfMonth(for: newMonth)
        }
    }

    private func goToToday() {
        displayedMonth = calendar.startOfMonth(for: .now)
    }

    /// Finds the persisted DayPlan for a date. `ensureDayPlansExist(for:)`
    /// (run from `.task`) guarantees this exists for any date currently on
    /// screen; the freshly-constructed fallback only covers the brief first
    /// frame before that task has run.
    private func dayPlan(for date: Date) -> DayPlan {
        let normalized = DayPlan.normalize(date)
        return allDayPlans.first { $0.date.isSameDay(as: normalized) } ?? DayPlan(date: normalized)
    }

    private func ensureDayPlansExist(for dates: [Date]) {
        for date in dates {
            let normalized = DayPlan.normalize(date)
            if !allDayPlans.contains(where: { $0.date.isSameDay(as: normalized) }) {
                modelContext.insert(DayPlan(date: normalized))
            }
        }
    }
}

private struct DayCell: View {
    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isPast: Bool
    let dayPlan: DayPlan

    private var dayNumber: String {
        String(Calendar.current.component(.day, from: date))
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(dayNumber)
                .font(.subheadline.weight(isToday ? .bold : .regular))
                .frame(width: 30, height: 30)
                .background {
                    if isToday {
                        Circle().fill(Color.accentColor)
                    }
                }
                .foregroundStyle(isToday ? Color.white : (isPast ? Color.secondary : Color.primary))

            statusDot
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .opacity(cellOpacity)
    }

    private var cellOpacity: Double {
        if !isCurrentMonth { return 0.25 }
        if isPast && !isToday { return 0.45 }
        return 1
    }

    @ViewBuilder
    private var statusDot: some View {
        switch dayPlan.kind {
        case .homeCookedRecipe:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .eatingOut:
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        case .unplanned:
            if dayPlan.suggestions.isEmpty {
                Color.clear.frame(width: 6, height: 6)
            } else {
                Circle().fill(Color.gray).frame(width: 6, height: 6)
            }
        }
    }
}
