import SwiftUI
import SwiftData

/// The Plan tab. Two ways to look at the same data:
/// - **Calendar**: a month grid up top (past days dimmed, today highlighted);
///   tapping a date anchors an agenda list below it showing that date and
///   everything after, so you can page months out and still see what's ahead.
/// - **This Week**: a flat agenda of just the current 7 days, for a quick
///   glance without the grid.
struct CalendarPlanView: View {
    @Binding var showPlanningFlow: Bool

    @Query(sort: \PlannedMeal.date) private var allPlannedMeals: [PlannedMeal]
    @Query(sort: \MealSuggestion.createdAt) private var allSuggestions: [MealSuggestion]

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var viewMode: PlanViewMode = .calendar

    private enum PlanViewMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar"
        case thisWeek = "This Week"
        var id: String { rawValue }
    }

    private var calendar: Calendar { Calendar.current }

    /// How many upcoming days the "X onward" agenda shows below the calendar —
    /// enough to actually be useful without querying/rendering an unbounded list.
    private static let agendaWindowInDays = 21

    private var isShowingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $viewMode) {
                ForEach(PlanViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            switch viewMode {
            case .calendar:
                calendarWithAgenda
            case .thisWeek:
                thisWeekAgenda
            }
        }
        .navigationTitle("Plan")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ActiveUserMenu()
            }
            if viewMode == .calendar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { goToToday() }
                        .disabled(isShowingCurrentMonth)
                }
            }
        }
        .fullScreenCover(isPresented: $showPlanningFlow) {
            PlanningReminderFlowView()
        }
    }

    // MARK: - Calendar mode

    private var calendarWithAgenda: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    monthHeader
                    legend
                    weekdayHeaderRow
                    monthGrid
                }
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(agendaDates, id: \.self) { day in
                    NavigationLink {
                        DayDetailView(date: day)
                    } label: {
                        AgendaDayRow(
                            date: day,
                            meals: meals(on: day),
                            suggestionCount: suggestionCount(on: day)
                        )
                    }
                }
            } header: {
                Text(agendaHeaderTitle)
            }
        }
        .listStyle(.plain)
    }

    private var agendaHeaderTitle: String {
        calendar.isDateInToday(selectedDate)
            ? "Today Onward"
            : "\(selectedDate.formatted(Date.weekdayFull)), \(selectedDate.formatted(Date.monthDay)) Onward"
    }

    private var agendaDates: [Date] {
        (0..<Self.agendaWindowInDays).compactMap {
            calendar.date(byAdding: .day, value: $0, to: selectedDate)
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
        .padding(.horizontal)
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
            ForEach(Array(calendar.orderedVeryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(calendar.gridDays(forMonthContaining: displayedMonth), id: \.self) { day in
                Button {
                    selectedDate = calendar.startOfDay(for: day)
                } label: {
                    DayCell(
                        date: day,
                        isCurrentMonth: calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isSelected: day.isSameDay(as: selectedDate),
                        isPast: day < calendar.startOfDay(for: .now),
                        meals: meals(on: day),
                        hasSuggestions: suggestionCount(on: day) > 0
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - This Week mode

    private var thisWeekAgenda: some View {
        let weekDays = calendar.daysOfWeek(containing: .now)
        return List {
            Section {
                ForEach(weekDays, id: \.self) { day in
                    NavigationLink {
                        DayDetailView(date: day)
                    } label: {
                        AgendaDayRow(
                            date: day,
                            meals: meals(on: day),
                            suggestionCount: suggestionCount(on: day)
                        )
                    }
                }
            } header: {
                Text("\(weekDays.first?.formatted(Date.monthDay) ?? "") – \(weekDays.last?.formatted(Date.monthDay) ?? "")")
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Shared helpers

    private func meals(on date: Date) -> [PlannedMeal] {
        allPlannedMeals.filter { $0.date.isSameDay(as: date) }
    }

    private func suggestionCount(on date: Date) -> Int {
        allSuggestions.filter { $0.date.isSameDay(as: date) }.count
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = calendar.startOfMonth(for: newMonth)
        }
    }

    private func goToToday() {
        displayedMonth = calendar.startOfMonth(for: .now)
        selectedDate = calendar.startOfDay(for: .now)
    }
}

private struct DayCell: View {
    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isPast: Bool
    let meals: [PlannedMeal]
    let hasSuggestions: Bool

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
                    } else if isSelected {
                        Circle().stroke(Color.accentColor, lineWidth: 1.5)
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
        if meals.contains(where: { $0.isHomeCooked }) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
        } else if meals.contains(where: { $0.isEatingOut }) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else if hasSuggestions {
            Circle().fill(Color.gray).frame(width: 6, height: 6)
        } else {
            Color.clear.frame(width: 6, height: 6)
        }
    }
}

private struct AgendaDayRow: View {
    let date: Date
    let meals: [PlannedMeal]
    let suggestionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(date.formatted(Date.weekdayFull)).font(.headline)
                Text(date.formatted(Date.monthDay)).font(.caption).foregroundStyle(.secondary)
                if Calendar.current.isDateInToday(date) {
                    Text("Today")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }

            if meals.isEmpty && suggestionCount == 0 {
                Text("Not planned").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    let slotMeals = meals.filter { $0.slot == slot }
                    if !slotMeals.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: slot.symbolName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(slotMeals.map(\.displayTitle).joined(separator: ", "))
                                .font(.subheadline)
                        }
                    }
                }
                if suggestionCount > 0 {
                    Text("\(suggestionCount) suggestion(s) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
