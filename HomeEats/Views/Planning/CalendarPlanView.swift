import SwiftUI
import SwiftData

/// The Plan tab. Two ways to look at the same data, switchable from the
/// segmented control up top; the "Go to This Week" button in the toolbar
/// stays visible in both:
/// - **Calendar**: a month grid up top (past days dimmed, today highlighted)
///   with the selected day's own full planner — every slot, not just
///   dinner — right below it, so deciding a day's meals never needs a
///   separate screen. Swipe the day header left/right (or use its chevrons,
///   or just tap a different date in the grid above) to move between days.
/// - **Weekly**: a flat agenda of just one week at a time (past days
///   dimmed, same as the calendar grid), with its own prev/next-week
///   navigation, for a quick glance across several days without the grid —
///   tapping a day here still pushes the full day screen.
///
/// There used to also be a separate "Start Planning" guided flow
/// (`PlanningReminderFlowView`, one day-at-a-time, dinner-only) reachable
/// from a toolbar button here. Removed per feedback that it was redundant
/// with — and less capable than — the Calendar mode's own inline day
/// panel, which already covers every slot for whichever day you're on.
struct CalendarPlanView: View {
    @Query(sort: \PlannedMeal.date) private var allPlannedMeals: [PlannedMeal]
    @Query(sort: \MealSuggestion.createdAt) private var allSuggestions: [MealSuggestion]

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var viewMode: PlanViewMode = .calendar
    /// Owned here, not inside `DaySlotsView` — and `.sheet(item:)` below is
    /// attached to `calendarWithAgenda`'s `List` itself, not to any content
    /// nested inside it. See the long note on `DaySlotsView.activeSheet` in
    /// DayDetailView.swift: presenting from inside this `List`'s own row
    /// content raced the `.animation(.default, value: selectedDate)` below
    /// (a `List`, backed by `UICollectionView`, can run an animated batch
    /// update over its rows concurrently with a `.sheet`'s own UIKit
    /// presentation animation when both are triggered close together, and
    /// the sheet loses that race — flashing on screen for a frame and being
    /// torn back down, "add a recipe" reopening fine on a second tap since
    /// there's no competing batch update the second time). Presenting from
    /// the `List`'s own root instead of its row content sidesteps that race
    /// entirely.
    @State private var activeSheet: SheetAction?
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ActiveUserMenu()
            }
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
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
                selectedDayHeader
                    .listRowSeparator(.hidden)
            }

            DaySlotsView(date: selectedDate, activeSheet: $activeSheet)
        }
        .listStyle(.plain)
        // Re-animates the day panel's content sliding to a new day's plan
        // whenever `selectedDate` changes, whether that came from the swipe
        // gesture on the header below, its chevrons, or tapping a different
        // date in the grid above — one consistent transition regardless of
        // which of the three actually changed it.
        .animation(.default, value: selectedDate)
        // Deliberately attached out here, to the `List` itself, rather than
        // to any content declared inside it — see `activeSheet` above.
        .sheet(item: $activeSheet) { action in
            MealSheetContent(action: action, date: selectedDate, activeSheet: $activeSheet)
        }
    }

    /// The selected day's own big header, styled like "Plan the Week"'s
    /// per-day card — swipe left/right on it (or use the chevrons) to move
    /// to an adjacent day without needing to tap back up in the grid.
    /// Deliberately not a `header:` — `List`/`Section` headers pin to the
    /// top while their section scrolls underneath, which here would have
    /// left this pinned in place while the calendar grid above scrolled up
    /// behind it — a plain row instead scrolls away with everything else.
    private var selectedDayHeader: some View {
        HStack {
            Button { moveSelectedDate(by: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(selectedDate.formatted(Date.weekdayFull)).font(.brandTitle2.bold())
                    if calendar.isDateInToday(selectedDate) {
                        Text("Today")
                            .font(.brandCaption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(selectedDate.formatted(Date.monthDay)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { moveSelectedDate(by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())
        // `.simultaneousGesture` rather than `.gesture` — this row still
        // sits inside the scrollable List above, and a plain `.gesture`
        // would claim every touch that starts here exclusively, including
        // an attempt to scroll the list starting from this exact row.
        // Simultaneous recognition lets both work: a horizontal swipe
        // changes the day (below), a vertical one still scrolls normally.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    // Horizontal swipe only — a mostly-vertical drag here is
                    // someone trying to scroll the list, not change days.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    moveSelectedDate(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private func moveSelectedDate(by days: Int) {
        guard let newDate = calendar.date(byAdding: .day, value: days, to: selectedDate) else { return }
        selectedDate = calendar.startOfDay(for: newDate)
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
                .foregroundStyle(Color.brandForest)
            Spacer()
            Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }
        }
        .foregroundStyle(Color.brandForest)
        .buttonStyle(.borderless)
    }

    private var thisWeekAgenda: some View {
        let today = calendar.startOfDay(for: .now)
        let days = weekDays
        return List {
            Section {
                weekHeader
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 4)

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
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
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
                // Same fix, same reasoning, as `GroupDayCell`'s identical
                // change in GroupSharedMealPlanView.swift — a two-digit day
                // number can clip inside this fixed circle at larger
                // Dynamic Type sizes without it.
                .minimumScaleFactor(0.6)
                .lineLimit(1)
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

    private var isEmpty: Bool { meals.isEmpty && suggestionCount == 0 }

    /// The same per-kind icon/color convention as the day screen's own
    /// `PlannedMealRow` and `SuggestionRow` — a recipe, an eat-out plan, and
    /// an order-in plan all read distinctly here too, and it's the same
    /// palette as the calendar grid's own legend dots above.
    private func iconName(for meal: PlannedMeal) -> String {
        if meal.recipe != nil { return "frying.pan" }
        return meal.isOrderingIn ? "bag" : "fork.knife"
    }
    private func iconColor(for meal: PlannedMeal) -> Color {
        if meal.recipe != nil { return .brandForest }
        return meal.isOrderingIn ? .brandHoney : .brandTerracotta
    }

    /// The card's own leading accent color — whichever kind of meal shows
    /// up first for the day (by slot order), or sage if nothing's decided
    /// yet but a suggestion is pending, or a neutral gray with nothing at
    /// all going on.
    private var accentColor: Color {
        if let firstMeal = meals.sorted(by: { $0.slot.sortIndex < $1.slot.sortIndex }).first {
            return iconColor(for: firstMeal)
        }
        return suggestionCount > 0 ? .brandSage : Color.secondary.opacity(0.3)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accentColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(date.formatted(Date.weekdayFull)).font(.brandHeadline)
                    Text(date.formatted(Date.monthDay)).font(.brandCaption).foregroundStyle(.secondary)
                    if Calendar.current.isDateInToday(date) {
                        Text("Today")
                            .font(.brandCaption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.brandForest))
                    }
                }

                if isEmpty {
                    Label("Not planned", systemImage: "circle.dashed")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                        let slotMeals = meals.filter { $0.slot == slot }
                        if !slotMeals.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: iconName(for: slotMeals[0]))
                                    .font(.brandCaption2)
                                    .foregroundStyle(iconColor(for: slotMeals[0]))
                                Text(slotMeals.map(\.displayTitle).joined(separator: ", "))
                                    .font(.brandSubheadline)
                            }
                        }
                    }
                    if suggestionCount > 0 {
                        Label("\(suggestionCount) suggestion(s) pending", systemImage: "hand.thumbsup")
                            .font(.brandCaption)
                            .foregroundStyle(Color.brandSage)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Calendar.current.isDateInToday(date) ? Color.brandForest.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .opacity(isPast ? 0.45 : 1)
    }
}
