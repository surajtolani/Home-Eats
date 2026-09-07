import SwiftUI
import SwiftData

/// The Plan tab. Two ways to look at the same data, switchable from the
/// segmented control up top; the "Go to This Week" button in the toolbar
/// stays visible in both:
/// - **Calendar**: a month grid up top (past days dimmed, today highlighted);
///   tapping a date anchors an agenda list below it showing that date and
///   everything after, so you can page months out and still see what's ahead.
/// - **Weekly**: a flat agenda of just one week at a time (past days
///   dimmed, same as the calendar grid), with its own prev/next-week
///   navigation, for a quick glance without the grid.
struct CalendarPlanView: View {
    @Binding var showPlanningFlow: Bool

    @Query(sort: \PlannedMeal.date) private var allPlannedMeals: [PlannedMeal]
    @Query(sort: \MealSuggestion.createdAt) private var allSuggestions: [MealSuggestion]

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var viewMode: PlanViewMode = .calendar
    /// Weeks away from the current week, for the Weekly agenda's own
    /// prev/next navigation — independent of Calendar mode's month/date
    /// state, since the two views page through time on different units.
    @State private var weekOffset: Int = 0

    private enum PlanViewMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar"
        case thisWeek = "Weekly"
        var id: String { rawValue }
    }

    private var calendar: Calendar { Calendar.current }

    /// How many upcoming days the "X onward" agenda shows below the calendar —
    /// enough to actually be useful without querying/rendering an unbounded list.
    private static let agendaWindowInDays = 21

    private var isShowingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    /// Whether the currently-active view mode is already showing "now", so
    /// the "Go to This Week" button can disable itself instead of sitting
    /// there as a no-op.
    private var isAtDefaultPosition: Bool {
        switch viewMode {
        case .calendar:
            return isShowingCurrentMonth && calendar.isDateInToday(selectedDate)
        case .thisWeek:
            return weekOffset == 0
        }
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
            ToolbarItem(placement: .topBarTrailing) {
                // The weekly notification also opens this flow, but that
                // depends on the reminder actually firing — this button is
                // the flow's only guaranteed-reachable entry point.
                Button {
                    showPlanningFlow = true
                } label: {
                    Label("Start Planning", systemImage: "wand.and.stars")
                }
            }
            // Visible in both view modes — not just Calendar — so switching
            // to Weekly never hides the way back to "now": it also resets
            // Calendar's own position (month + selected date) in the
            // background, so Calendar is back on the current month whenever
            // you next switch to it, even if you never revisit it directly.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Go to This Week") { goToThisWeek() }
                    .disabled(isAtDefaultPosition)
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
                // Deliberately not a `header:` — `List`/`Section` headers
                // pin to the top while their section scrolls underneath,
                // which here meant this title stayed fixed in place while
                // the calendar grid above scrolled up behind it. As a plain
                // row instead, it scrolls away with everything else.
                Text(agendaHeaderTitle)
                    .font(.brandHeadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)

                ForEach(agendaDates, id: \.self) { day in
                    NavigationLink {
                        DayDetailView(date: day)
                    } label: {
                        AgendaDayRow(
                            date: day,
                            meals: meals(on: day),
                            suggestionCount: suggestionCount(on: day),
                            // This agenda only ever lists selectedDate and
                            // days after it, so it never actually contains a
                            // past day — explicit false rather than computing
                            // it, since it'd always evaluate to false anyway.
                            isPast: false
                        )
                    }
                }
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
                .font(.brandTitle2.bold())
            Spacer()
            Button { changeMonth(by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: .brandForest, label: "Cooking")
            legendItem(color: .brandTerracotta, label: "Eating out")
            legendItem(color: .brandHoney, label: "Order in")
            legendItem(color: .brandSage, label: "Suggested")
        }
        .font(.brandCaption)
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
                    .font(.brandCaption2.bold())
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

    // MARK: - Weekly mode

    private var weekDays: [Date] {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return calendar.daysOfWeek(containing: base)
    }

    private var weekRangeText: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        return "\(first.formatted(Date.monthDay)) – \(last.formatted(Date.monthDay))"
    }

    private var weekHeader: some View {
        HStack {
            Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(weekRangeText)
                .font(.brandTitle2.bold())
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
    }

    private var thisWeekAgenda: some View {
        let today = calendar.startOfDay(for: .now)
        let days = weekDays
        return List {
            Section {
                weekHeader
                    .listRowSeparator(.hidden)

                ForEach(days, id: \.self) { day in
                    NavigationLink {
                        DayDetailView(date: day)
                    } label: {
                        AgendaDayRow(
                            date: day,
                            meals: meals(on: day),
                            suggestionCount: suggestionCount(on: day),
                            isPast: day < today
                        )
                    }
                }
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

    private func goToThisWeek() {
        displayedMonth = calendar.startOfMonth(for: .now)
        selectedDate = calendar.startOfDay(for: .now)
        weekOffset = 0
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
                .font(.brandSubheadline.weight(isToday ? .bold : .regular))
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
            Circle().fill(Color.brandForest).frame(width: 6, height: 6)
        } else if meals.contains(where: { $0.isEatingOut }) {
            Circle().fill(Color.brandTerracotta).frame(width: 6, height: 6)
        } else if meals.contains(where: { $0.isOrderingIn }) {
            Circle().fill(Color.brandHoney).frame(width: 6, height: 6)
        } else if hasSuggestions {
            Circle().fill(Color.brandSage).frame(width: 6, height: 6)
        } else {
            Color.clear.frame(width: 6, height: 6)
        }
    }
}

private struct AgendaDayRow: View {
    let date: Date
    let meals: [PlannedMeal]
    let suggestionCount: Int
    let isPast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(date.formatted(Date.weekdayFull)).font(.brandHeadline)
                Text(date.formatted(Date.monthDay)).font(.brandCaption).foregroundStyle(.secondary)
                if Calendar.current.isDateInToday(date) {
                    Text("Today")
                        .font(.brandCaption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }

            if meals.isEmpty && suggestionCount == 0 {
                Text("Not planned").font(.brandSubheadline).foregroundStyle(.secondary)
            } else {
                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    let slotMeals = meals.filter { $0.slot == slot }
                    if !slotMeals.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: slot.symbolName)
                                .font(.brandCaption2)
                                .foregroundStyle(.secondary)
                            Text(slotMeals.map(\.displayTitle).joined(separator: ", "))
                                .font(.brandSubheadline)
                        }
                    }
                }
                if suggestionCount > 0 {
                    Text("\(suggestionCount) suggestion(s) pending")
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(isPast ? 0.45 : 1)
    }
}
