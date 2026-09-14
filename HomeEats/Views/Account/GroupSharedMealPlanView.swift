import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// A single group's own meal plan — day-by-day decided meals and pending
/// suggestions, scoped to one `groupID` (never shared across groups; each
/// group has its own independent plan). This is what the main "Plan" tab
/// shows for whichever group is currently active (see `GroupScopedPlanTab`
/// in RootView.swift), and is also reachable directly from
/// `GroupDetailView`'s "Meal Plan" link for a non-active group.
///
/// **Calendar / Weekly, same as the personal planner**: this screen ports
/// `CalendarPlanView`/`DayDetailView`'s exact visual/interaction design (see
/// those files' own doc comments — they stay untouched, personal/local-only
/// reference views per this feature's scope) onto the group-scoped,
/// offline-capable, backend-synced `GroupPlannedMeal`/`GroupMealSuggestion`
/// models instead of the personal `PlannedMeal`/`MealSuggestion` ones: a
/// segmented **Calendar** (month grid, today's day panel inline right below
/// it, swipe/chevron between days) / **Weekly** (flat 7-day agenda, tap a
/// day to push the full per-slot screen) toggle, "Go to This Week", and the
/// same Breakfast/Lunch/Dinner/Other per-slot layout with the icon+pill
/// decided-meal row and vote-count/"Use This" suggestion row. The actual
/// per-slot content lives in `GroupDaySlotsView` below, embedded inline here
/// (Calendar mode) and pushed via `GroupDayDetailView` (Weekly mode's tap
/// target) — same split, and the same reasoning for it, as the personal
/// `DaySlotsView`/`DayDetailView`.
///
/// **Local-first**: every row shown here comes straight from the on-device
/// SwiftData store, so this screen reads and writes instantly whether
/// online or off. `GroupSyncService.sync` runs in the background — on
/// appearance, on pull-to-refresh, and on a light periodic timer for as
/// long as this screen stays on-screen (the `while` loop inside `.task`
/// below, cancelled automatically the moment SwiftUI tears this view down)
/// — to push whatever's pending and pull the group's latest state. See
/// `GroupSyncService`'s own doc comment for the full sync/reconcile design
/// and its "Known limitations" note.
///
/// **Role gating**: mirrors the backend's own MANAGER/PARTICIPANT split
/// exactly (see routes/groupMealPlan.js) — a `MANAGER` sees "Add a Recipe"/
/// "Eat Out"/"Order In" (decides a meal directly) and "Use This" (adopts a
/// suggestion); a `PARTICIPANT` only ever sees the "Suggest instead"/
/// "Suggest for a Vote" menu and the vote button itself, same "never offer
/// an action that would just 403" standard the rest of this feature holds
/// to (see `GroupDaySlotsView.slotSection`, which mirrors the *shape* of the
/// personal `DaySlotsView.slotSection`'s decide-vs-suggest button split,
/// gated here by role instead of by nothing at all).
///
/// **Switching groups**: `GroupScopedPlanTab` in RootView.swift gives this
/// view a fresh `.id(group.id)` whenever the active group changes, which
/// tears the whole view down and rebuilds it from scratch — every `@State`
/// property here (`selectedDate`, `viewMode`, `displayedMonth`,
/// `weekOffset`, ...) resets to its declared default rather than leaking
/// across a group switch; see that wrapper's own doc comment.
struct GroupSharedMealPlanView: View {
    let groupID: String
    let groupName: String

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession

    @Query private var plannedMeals: [GroupPlannedMeal]
    @Query private var suggestions: [GroupMealSuggestion]

    @State private var group: GroupDetail?
    @State private var lastSyncOutcome: GroupSyncService.SyncOutcome?
    @State private var actionErrorMessage: String?

    // MARK: - Calendar/Weekly view state — same shape as CalendarPlanView's
    // own `@State`, see that file's doc comment for the reasoning behind
    // each one.
    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var viewMode: PlanViewMode = .calendar
    @State private var weekOffset: Int = 0
    /// Owned here (the Calendar mode's inline day panel), not inside
    /// `GroupDaySlotsView` — see the long note on `DaySlotsView.activeSheet`
    /// in the personal DayDetailView.swift for the full reasoning (a `List`
    /// animated via `.animation(.default, value: selectedDate)` can race a
    /// `.sheet` presented from inside its own row content); `.sheet(item:)`
    /// below is attached to `calendarWithAgenda`'s `List` itself for the
    /// same reason.
    @State private var activeSheet: GroupSheetAction?

    private enum PlanViewMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar"
        case thisWeek = "Weekly"
        var id: String { rawValue }
    }

    init(groupID: String, groupName: String) {
        self.groupID = groupID
        self.groupName = groupName
        // Captured into a local constant before use inside `#Predicate`,
        // matching this codebase's own established caution around what
        // that macro can reliably close over — see `GroupSyncService`'s
        // identical pattern.
        let gid = groupID
        _plannedMeals = Query(filter: #Predicate<GroupPlannedMeal> { $0.groupID == gid }, sort: \GroupPlannedMeal.date)
        _suggestions = Query(filter: #Predicate<GroupMealSuggestion> { $0.groupID == gid }, sort: \GroupMealSuggestion.date)
    }

    private var calendar: Calendar { Calendar.current }
    private var myRole: GroupRole? { group?.myRole(currentUserID: accountSession.currentUser?.id) }
    private var isManager: Bool { myRole == .manager }

    /// The `@Query` results with any `.pendingDelete` row filtered out —
    /// every view below reads through these, never `plannedMeals`/
    /// `suggestions` directly, so a swipe-to-delete/withdraw removes a row
    /// from view immediately (optimistic), rather than leaving it fully
    /// visible and interactive until the next successful push actually
    /// removes it from the store.
    private var visiblePlannedMeals: [GroupPlannedMeal] {
        plannedMeals.filter { $0.syncState != .pendingDelete }
    }
    private var visibleSuggestions: [GroupMealSuggestion] {
        suggestions.filter { $0.syncState != .pendingDelete }
    }

    private var hasPendingChanges: Bool {
        plannedMeals.contains { $0.syncState != .synced } || suggestions.contains { $0.syncState != .synced }
    }

    /// Whether the last completed sync couldn't reach the server at all —
    /// used to disable the online-only manager actions (`Use This`) rather
    /// than let them fail with a confusing error every time.
    private var isKnownOffline: Bool {
        guard let lastSyncOutcome else { return false }
        return !lastSyncOutcome.pullSucceeded
    }

    private var isShowingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
    }

    /// Whether the currently-active view mode is already showing "now", so
    /// the "Go to This Week" button can disable itself instead of sitting
    /// there as a no-op — same reasoning as `CalendarPlanView`'s own.
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
            // The Calendar/Weekly toggle AND "Go to This Week" together —
            // the "row below" the shared static `GroupTopBar` (see that
            // type's own doc comment for the top-bar redesign this
            // implements). "Go to This Week" used to be a `.topBarTrailing`
            // toolbar item in this view's own `.toolbar` — moved here
            // instead, per direct user request that the top bar itself stay
            // static with only the group switcher/notifications/account
            // icons on it, and "all the other things like go to week or
            // share or heart or anything else" go in a row underneath.
            // A sibling of the `switch` below, not nested inside either of
            // its branches — visible in both view modes, same as the
            // toolbar button this replaced.
            HStack(spacing: 8) {
                Picker("View", selection: $viewMode) {
                    ForEach(PlanViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button("This Week") { goToThisWeek() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // `.pickerStyle(.segmented)`'s rendered label size comes
                    // from `UISegmentedControl`'s own default title font (a
                    // fixed 13pt regular — `.footnote` is SwiftUI's exact
                    // equivalent size), not from any `Font` set on the
                    // `Text` inside each segment — so a SwiftUI `Text`
                    // modifier there wouldn't actually change what's
                    // rendered, which is why this button (using
                    // `.controlSize(.small)`'s own smaller default text
                    // size) read visibly smaller than "Calendar"/"Weekly"
                    // right next to it. Matching that fixed 13pt here
                    // explicitly is what actually fixes it.
                    .font(.footnote)
                    .disabled(isAtDefaultPosition)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // `.syncStatusOverlay` (see `SyncStatusBanner.swift`) floats
            // this at the BOTTOM of the switch content — a true overlay,
            // not a row inserted into/removed from the layout, so it can
            // never shift `calendarWithAgenda`/`thisWeekAgenda` or the
            // Picker/"This Week" row above them, no matter how often
            // voting flickers `hasPendingChanges` (see that shared type's
            // own doc comment for the full "screen jumps on every vote"
            // bug this fixes). Bottom rather than top — direct follow-up
            // user request, moved here from where it first landed, so it
            // stays out of the way of whatever's actually being glanced at.
            switch viewMode {
            case .calendar:
                calendarWithAgenda
            case .thisWeek:
                thisWeekAgenda
            }
        }
        .syncStatusOverlay(isVisible: hasPendingChanges || isKnownOffline, message: statusMessage)
        .navigationTitle(group?.name ?? groupName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadGroup()
            await runSync()
            await runPeriodicSyncLoop()
        }
        .refreshable { await runSync() }
        .alert(
            "Couldn't complete that",
            isPresented: Binding(get: { actionErrorMessage != nil }, set: { if !$0 { actionErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private var statusMessage: String {
        if hasPendingChanges {
            return "Some changes haven't synced yet — they'll go out automatically once you're back online."
        }
        return "Couldn't reach the server — showing what was last synced."
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

            GroupDaySlotsView(
                groupID: groupID, date: selectedDate, isManager: isManager,
                currentUserID: accountSession.currentUser?.id, group: group, isKnownOffline: isKnownOffline,
                activeSheet: $activeSheet, onLocalWrite: { Task { await runSync() } },
                onError: { message in actionErrorMessage = message }
            )
        }
        .listStyle(.plain)
        // Re-animates the day panel's content sliding to a new day's plan —
        // same reasoning as `CalendarPlanView`'s identical modifier.
        .animation(.default, value: selectedDate)
        // Deliberately attached out here, to the `List` itself, rather than
        // to any content declared inside it — see `activeSheet` above.
        .sheet(item: $activeSheet) { action in
            GroupMealSheetContent(action: action, groupID: groupID, date: selectedDate, currentUserID: accountSession.currentUser?.id)
        }
    }

    /// The selected day's own big header — identical structure to
    /// `CalendarPlanView.selectedDayHeader`, including its swipe-to-change-day
    /// gesture; see that property's own doc comment for why it's a plain row
    /// (not a `header:`) and why the gesture is `.simultaneousGesture`.
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
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
                    GroupDayCell(
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
                        GroupDayDetailView(
                            groupID: groupID, date: day, isManager: isManager,
                            currentUserID: accountSession.currentUser?.id, group: group, isKnownOffline: isKnownOffline,
                            onLocalWrite: { Task { await runSync() } },
                            onError: { message in actionErrorMessage = message }
                        )
                    } label: {
                        GroupAgendaDayRow(
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
        // User feedback: "under weekly view, please delete the arrows on
        // the right - since you can click on the actual day and it goes to
        // the same place, cleaner layout." Each row above is already a
        // `NavigationLink` to the exact same destination `GroupDayDetailView`
        // push — the trailing chevron `List` draws on top of a
        // `NavigationLink` row is pure redundant decoration here, not a
        // second, different way to navigate. `.navigationLinkIndicatorVisibility(.hidden)`
        // (iOS 16.4+, well within this project's 17.0 deployment target —
        // see project.yml) hides just that chevron while leaving the whole
        // row exactly as tappable as before; it does NOT touch `weekHeader`'s
        // own chevrons just above (those are real week-to-week navigation,
        // `weekOffset -= 1`/`+= 1` — a completely different, non-redundant
        // control the user's feedback wasn't about).
        .navigationLinkIndicatorVisibility(.hidden)
    }

    // MARK: - Shared helpers

    private func meals(on date: Date) -> [GroupPlannedMeal] {
        visiblePlannedMeals.filter { $0.date.isSameDay(as: date) }
    }

    private func suggestionCount(on date: Date) -> Int {
        visibleSuggestions.filter { $0.date.isSameDay(as: date) }.count
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

    // MARK: - Sync

    private func loadGroup() async {
        group = try? await AccountsAPIClient.getGroup(id: groupID)
    }

    private func runSync() async {
        lastSyncOutcome = await GroupSyncService.sync(groupID: groupID, modelContext: modelContext)
    }

    /// Same "plain `Task.sleep` loop, cancelled automatically on disappear"
    /// design as the original group screens' own periodic resync — see
    /// `GroupSyncService`'s doc comment for the full reasoning.
    private func runPeriodicSyncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            await runSync()
        }
    }
}

// MARK: - Calendar-grid day cell

private struct GroupDayCell: View {
    let date: Date
    let isCurrentMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isPast: Bool
    let meals: [GroupPlannedMeal]
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

    /// One dot per distinct category actually present that day — matching
    /// the always-multi-category `legend` above (Cooking/Eating out/Order
    /// in/Suggested), rather than the single highest-priority dot this used
    /// to collapse down to. A day with both a home-cooked lunch and a
    /// restaurant dinner planned now shows both a forest and a terracotta
    /// dot side by side, not just the first one an if/else-if chain happened
    /// to check first — that used to silently hide real information ("what
    /// else is going on that day?") the calendar's whole job is to surface
    /// at a glance.
    @ViewBuilder
    private var statusDot: some View {
        let hasHomeCooked = meals.contains { $0.isHomeCooked }
        let hasEatingOut = meals.contains { $0.isEatingOut }
        let hasOrderingIn = meals.contains { $0.isOrderingIn }

        if !hasHomeCooked && !hasEatingOut && !hasOrderingIn && !hasSuggestions {
            Color.clear.frame(width: 6, height: 6)
        } else {
            HStack(spacing: 3) {
                if hasHomeCooked {
                    Circle().fill(Color.brandForest).frame(width: 6, height: 6)
                }
                if hasEatingOut {
                    Circle().fill(Color.brandTerracotta).frame(width: 6, height: 6)
                }
                if hasOrderingIn {
                    Circle().fill(Color.brandHoney).frame(width: 6, height: 6)
                }
                // Suggested only shown once nothing's actually decided yet
                // for the day — once at least one meal IS decided, a
                // still-pending suggestion for some other slot isn't worth
                // its own dot in this already-multi-dot view; the day
                // detail screen is where that suggestion is still fully
                // visible and actionable.
                if hasSuggestions && !hasHomeCooked && !hasEatingOut && !hasOrderingIn {
                    Circle().fill(Color.brandSage).frame(width: 6, height: 6)
                }
            }
        }
    }
}

// MARK: - Weekly-agenda row

private struct GroupAgendaDayRow: View {
    let date: Date
    let meals: [GroupPlannedMeal]
    let suggestionCount: Int
    let isPast: Bool

    private var isEmpty: Bool { meals.isEmpty && suggestionCount == 0 }

    private func iconName(for meal: GroupPlannedMeal) -> String {
        if meal.isHomeCooked { return "frying.pan" }
        return meal.isOrderingIn ? "bag" : "fork.knife"
    }
    private func iconColor(for meal: GroupPlannedMeal) -> Color {
        if meal.isHomeCooked { return .brandForest }
        return meal.isOrderingIn ? .brandHoney : .brandTerracotta
    }

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

// MARK: - Pushed day screen (Weekly mode's tap target)

/// Same relationship to `GroupDaySlotsView` as the personal `DayDetailView`
/// has to `DaySlotsView` — this is just the `Form`/navigation-title chrome a
/// standalone pushed screen needs; all the actual slot logic lives in
/// `GroupDaySlotsView`, shared with `GroupSharedMealPlanView`'s own inline
/// Calendar-mode day panel.
struct GroupDayDetailView: View {
    let groupID: String
    let date: Date
    let isManager: Bool
    let currentUserID: String?
    let group: GroupDetail?
    let isKnownOffline: Bool
    let onLocalWrite: () -> Void
    let onError: (String) -> Void

    // Owned here rather than inside `GroupDaySlotsView` — see the note on
    // `GroupSharedMealPlanView.activeSheet` for why.
    @State private var activeSheet: GroupSheetAction?

    var body: some View {
        Form {
            GroupDaySlotsView(
                groupID: groupID, date: date, isManager: isManager, currentUserID: currentUserID,
                group: group, isKnownOffline: isKnownOffline, activeSheet: $activeSheet,
                onLocalWrite: onLocalWrite, onError: onError
            )
        }
        .navigationTitle(date.formatted(Date.weekdayFull))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { action in
            GroupMealSheetContent(action: action, groupID: groupID, date: date, currentUserID: currentUserID)
        }
    }
}

// MARK: - Per-day, per-slot content (the actual meal-plan UI)

/// The group-scoped counterpart of the personal `DaySlotsView` — one day's
/// plan broken into Breakfast / Lunch / Dinner / Other, each slot able to
/// hold more than one decided meal and any number of pending suggestions,
/// plus per-slot decide/suggest actions. Embedded inline
/// (`GroupSharedMealPlanView`'s Calendar-mode day panel) and pushed
/// (`GroupDayDetailView`, Weekly mode's tap target) without duplicating any
/// of this logic — same split as the personal `DaySlotsView`/`DayDetailView`,
/// see either's doc comment for the reasoning.
struct GroupDaySlotsView: View {
    let groupID: String
    let date: Date
    let isManager: Bool
    let currentUserID: String?
    let group: GroupDetail?
    let isKnownOffline: Bool
    /// Which sheet slot/meal action is pending, if any — owned by whichever
    /// screen embeds this view, not by this view itself. See
    /// `GroupSharedMealPlanView.activeSheet`'s own doc comment for the full
    /// "why not owned here" reasoning (identical to the personal
    /// `DaySlotsView.activeSheet`'s).
    @Binding var activeSheet: GroupSheetAction?
    /// Called after every local write (decide, suggest, vote, remove,
    /// withdraw) to kick off a background push/pull cycle — this view has
    /// no `SyncOutcome` of its own to update, so it simply asks whichever
    /// screen embeds it to re-run its own `runSync()`.
    let onLocalWrite: () -> Void
    /// Surfaces an online-only action's failure (currently just "Use This")
    /// as the embedding screen's own alert, rather than this view needing
    /// its own alert-presentation state.
    let onError: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var allPlannedMeals: [GroupPlannedMeal]
    @Query private var allSuggestions: [GroupMealSuggestion]

    init(
        groupID: String, date: Date, isManager: Bool, currentUserID: String?, group: GroupDetail?,
        isKnownOffline: Bool, activeSheet: Binding<GroupSheetAction?>,
        onLocalWrite: @escaping () -> Void, onError: @escaping (String) -> Void
    ) {
        self.groupID = groupID
        self.date = date
        self.isManager = isManager
        self.currentUserID = currentUserID
        self.group = group
        self.isKnownOffline = isKnownOffline
        self._activeSheet = activeSheet
        self.onLocalWrite = onLocalWrite
        self.onError = onError
        // Same captured-local-constant `#Predicate` caution as
        // `GroupSharedMealPlanView.init` — see its own comment.
        let gid = groupID
        _allPlannedMeals = Query(filter: #Predicate<GroupPlannedMeal> { $0.groupID == gid }, sort: \GroupPlannedMeal.decidedAt)
        _allSuggestions = Query(filter: #Predicate<GroupMealSuggestion> { $0.groupID == gid }, sort: \GroupMealSuggestion.createdAt)
    }

    private var normalizedDate: Date { GroupPlannedMeal.normalize(date) }

    private func meals(for slot: MealSlot) -> [GroupPlannedMeal] {
        allPlannedMeals.filter { $0.syncState != .pendingDelete && $0.date.isSameDay(as: normalizedDate) && $0.slot == slot }
    }

    private func suggestions(for slot: MealSlot) -> [GroupMealSuggestion] {
        allSuggestions
            .filter { $0.syncState != .pendingDelete && $0.date.isSameDay(as: normalizedDate) && $0.slot == slot }
            // Net score (upvotes minus downvotes), highest first — same
            // "most popular suggestion floats to the top" ordering the old
            // upvote-only `voteCount` sort gave, generalized now that a
            // suggestion can also collect downvotes.
            .sorted { $0.upvoteCount - $0.downvoteCount > $1.upvoteCount - $1.downvoteCount }
    }

    private func memberName(_ userID: String) -> String {
        group?.members.first(where: { $0.id == userID })?.displayNameOrPhoneNumber ?? "Someone"
    }

    var body: some View {
        ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
            slotSection(slot)
        }
    }

    @ViewBuilder
    private func slotSection(_ slot: MealSlot) -> some View {
        let isEmpty = meals(for: slot).isEmpty && suggestions(for: slot).isEmpty

        Section {
            ForEach(meals(for: slot)) { meal in
                GroupPlannedMealRow(
                    meal: meal, memberName: memberName(meal.decidedByUserID), isManager: isManager,
                    onRemove: { removePlannedMeal(meal) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }
            ForEach(suggestions(for: slot)) { suggestion in
                GroupSuggestionRow(
                    suggestion: suggestion, proposerName: memberName(suggestion.proposedByUserID),
                    isManager: isManager,
                    canRemove: isManager || suggestion.proposedByUserID == currentUserID,
                    isKnownOffline: isKnownOffline,
                    onVote: { direction in vote(suggestion, direction: direction) },
                    onAdopt: { Task { await adopt(suggestion) } },
                    onRemove: { withdrawSuggestion(suggestion) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }

            // MANAGER-only "decide now" buttons (green), plus a "suggest
            // instead" row open to everyone. A PARTICIPANT sees only the
            // suggest row — as its own three boxes, matching the MANAGER
            // row's shape exactly rather than a single Menu button, so
            // "here are your three options" reads the same way regardless
            // of role — just in `.brandSage` instead of `.brandForest`, so
            // the two rows are still tellable apart at a glance as "decide"
            // vs. "suggest" (a MANAGER, who sees both rows stacked, gets
            // that same visual cue). Was `.brandTerracotta` — changed per
            // direct user request.
            VStack(spacing: 4) {
                if isManager {
                    HStack(spacing: 8) {
                        GroupSlotAddButton(title: "Add a Recipe", systemImage: "frying.pan") {
                            activeSheet = .addRecipe(slot)
                        }
                        GroupSlotAddButton(title: "Eat Out", systemImage: "fork.knife") {
                            activeSheet = .addRestaurant(slot, isOrderIn: false)
                        }
                        GroupSlotAddButton(title: "Order In", systemImage: "bag") {
                            activeSheet = .addRestaurant(slot, isOrderIn: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    GroupSlotAddButton(title: "Suggest a Recipe", systemImage: "frying.pan", tint: .brandSage) {
                        activeSheet = .suggestRecipe(slot)
                    }
                    GroupSlotAddButton(title: "Suggest Eat Out", systemImage: "fork.knife", tint: .brandSage) {
                        activeSheet = .suggestRestaurant(slot, isOrderIn: false)
                    }
                    GroupSlotAddButton(title: "Suggest Order In", systemImage: "bag", tint: .brandSage) {
                        activeSheet = .suggestRestaurant(slot, isOrderIn: true)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: isEmpty ? 14 : 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        } header: {
            Label(slot.displayName, systemImage: slot.symbolName)
        }
    }

    // MARK: - Actions

    private func vote(_ suggestion: GroupMealSuggestion, direction: VoteDirection) {
        suggestion.voteLocally(direction)
        try? modelContext.save()
        onLocalWrite()
    }

    private func removePlannedMeal(_ meal: GroupPlannedMeal) {
        if meal.isLocalPlaceholderID {
            modelContext.delete(meal)
        } else {
            meal.syncState = .pendingDelete
        }
        try? modelContext.save()
        onLocalWrite()
    }

    private func withdrawSuggestion(_ suggestion: GroupMealSuggestion) {
        if suggestion.isLocalPlaceholderID {
            modelContext.delete(suggestion)
        } else {
            suggestion.syncState = .pendingDelete
        }
        try? modelContext.save()
        onLocalWrite()
    }

    /// MANAGER-only, immediate/online-only — see `GroupSyncService`'s
    /// "Known limitations" note for why adopting a suggestion isn't queued
    /// for offline push the way every other write on this screen is.
    private func adopt(_ suggestion: GroupMealSuggestion) async {
        do {
            try await GroupSyncService.adoptSuggestion(groupID: groupID, suggestionID: suggestion.id, modelContext: modelContext)
        } catch {
            onError(error.localizedDescription)
        }
    }
}

// MARK: - Rows

private struct GroupPlannedMealRow: View {
    let meal: GroupPlannedMeal
    let memberName: String
    let isManager: Bool
    let onRemove: () -> Void

    /// Same icon+color convention as the personal `PlannedMealRow` — a
    /// recipe, an eat-out plan, and an order-in plan all read distinctly at
    /// a glance here too, and it's the same palette as the calendar's own
    /// legend/status dots.
    private var iconName: String {
        if meal.isHomeCooked { return "frying.pan" }
        return meal.isOrderingIn ? "bag" : "fork.knife"
    }
    private var iconColor: Color {
        if meal.isHomeCooked { return .brandForest }
        return meal.isOrderingIn ? .brandHoney : .brandTerracotta
    }

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: iconName).foregroundStyle(iconColor)
                Text(meal.displayTitle)
            }
            .font(.brandHeadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(iconColor.opacity(0.12), in: Capsule())

            Spacer()
            if meal.syncState != .synced { pendingIndicator }
            Text("by \(memberName)")
                .font(.brandCaption2)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            // MANAGER only — mirrors `DELETE /groups/:groupId/meal-plan/:id`
            // exactly (see routes/groupMealPlan.js).
            if isManager {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

private struct GroupSuggestionRow: View {
    let suggestion: GroupMealSuggestion
    let proposerName: String
    let isManager: Bool
    let canRemove: Bool
    let isKnownOffline: Bool
    let onVote: (VoteDirection) -> Void
    let onAdopt: () -> Void
    let onRemove: () -> Void

    /// Same icon/color convention as `GroupPlannedMealRow` once something's
    /// actually decided — checks `recipeID` directly (this model has no
    /// `isHomeCooked`-style computed property of its own, unlike
    /// `GroupPlannedMeal`) the same way the personal `SuggestionRow` checks
    /// `suggestion.recipe != nil`.
    private var iconName: String {
        if suggestion.recipeID != nil { return "frying.pan" }
        return suggestion.isOrderIn ? "bag" : "fork.knife"
    }
    private var iconColor: Color {
        if suggestion.recipeID != nil { return .brandForest }
        return suggestion.isOrderIn ? .brandHoney : .brandTerracotta
    }

    var body: some View {
        HStack {
            Image(systemName: iconName).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.displayTitle).font(.brandSubheadline)
                Text("Suggested by \(proposerName)")
                    .font(.brandCaption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if suggestion.syncState != .synced { pendingIndicator }
            // Voting is open to every member, regardless of role — mirrors
            // `POST .../suggestions/:id/vote`, which has no role gate at
            // all (see routes/groupMealPlan.js). Two separate small
            // controls, not one toggle, now that a vote has a direction —
            // each shows its own count (not a single collapsed net score)
            // so "2 people like this, 1 doesn't" stays legible at a glance,
            // matching the backend's own `upvoteCount`/`downvoteCount` split
            // (see `serializeSuggestion(...)`'s doc comment in
            // routes/groupMealPlan.js for why that split, not a net number,
            // is what the API returns in the first place).
            //
            // Explicit, fixed-size capsule buttons — direct user request to
            // make these smaller ("make the thumbs up, thumbs down and use
            // it icons smaller so the recipe or restaurant length extends
            // further to the right"), and to keep them small when a later
            // report said they'd "become larger again." That second report
            // is why this isn't `.buttonStyle(.bordered) + .controlSize
            // (.mini)` (what this row used before): `.mini` is a *hint*, not
            // a guaranteed pixel size — iOS bordered buttons keep a fairly
            // generous minimum rendered size across control sizes for
            // tappability, so a system font-size bump (Dynamic Type, or
            // just a build where the system rendered it a notch larger)
            // could make a `.mini` bordered button read as "large again"
            // despite nothing in this file changing. A hand-rolled capsule
            // with an explicit `.brandCaption2` font and fixed padding has
            // no such wiggle room: what's specified here is what renders,
            // every time.
            Button {
                onVote(.up)
            } label: {
                voteCapsule(
                    count: suggestion.upvoteCount,
                    systemImage: suggestion.myVote == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                    tint: .brandForest, isActive: suggestion.myVote == .up
                )
            }
            .buttonStyle(.plain)

            Button {
                onVote(.down)
            } label: {
                voteCapsule(
                    count: suggestion.downvoteCount,
                    systemImage: suggestion.myVote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    tint: .brandTerracotta, isActive: suggestion.myVote == .down
                )
            }
            .buttonStyle(.plain)
            // MANAGER only — mirrors `POST .../suggestions/:id/adopt`
            // exactly. Disabled while offline or still a not-yet-synced
            // placeholder row (the server doesn't know its real id yet).
            if isManager {
                let isDisabled = isKnownOffline || suggestion.isLocalPlaceholderID
                Button(action: onAdopt) {
                    Text("Use This")
                        .font(.brandCaption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(isDisabled ? Color.secondary : Color.brandForest))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
        .swipeActions(edge: .trailing) {
            // MANAGER, or the suggestion's own proposer — mirrors
            // `DELETE .../suggestions/:id` exactly.
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    /// The vote buttons' shared visual — an icon + count in a small
    /// capsule, filled/tinted when this is the caller's own vote and
    /// outlined/secondary otherwise. Purely presentational (this is
    /// `Button`'s `label:`, never tappable on its own).
    private func voteCapsule(count: Int, systemImage: String, tint: Color, isActive: Bool) -> some View {
        Label("\(count)", systemImage: systemImage)
            .font(.brandCaption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isActive ? tint : Color.secondary)
            .background(
                Capsule()
                    .fill(isActive ? tint.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .overlay(
                Capsule().strokeBorder(isActive ? tint.opacity(0.4) : Color.secondary.opacity(0.25))
            )
    }
}

private var pendingIndicator: some View {
    Image(systemName: "arrow.triangle.2.circlepath")
        .font(.brandCaption2)
        .foregroundStyle(.secondary)
        .help("Not synced yet")
}

/// One of the three single-tap "decide now" buttons in a slot section — same
/// deliberately small/quiet visual treatment as the personal `SlotAddButton`
/// (see that type's own doc comment for why `.plain` + a hand-drawn fill,
/// not `.bordered`).
private struct GroupSlotAddButton: View {
    let title: String
    let systemImage: String
    /// `.brandForest` (a MANAGER deciding a meal directly) by default —
    /// every existing call site keeps that color unchanged. The PARTICIPANT
    /// "suggest" row below passes `.brandTerracotta` instead, so the two
    /// rows read as visually distinct actions (decide vs. suggest) at a
    /// glance, not just via their different button labels.
    var tint: Color = .brandForest
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: 9.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add / suggest a meal (sheet)

/// Identifies which sheet is presented, and with what context — the
/// group-scoped counterpart of the personal `SheetAction`. Deliberately has
/// no `setOrderReminder`/`logMeal` cases: order reminders
/// (`NotificationScheduler`) and meal-history logging (`MealHistoryEntry`)
/// are both purely local/personal-device features with no group-scoped
/// backend counterpart at all, so they're out of scope here — see this
/// feature's own final report. `addRestaurant`/`suggestRestaurant` fold the
/// personal enum's separate `addRestaurant`/`orderIn` cases into one, with
/// an `isOrderIn` flag, since the group restaurant flow is a single
/// name-entry sheet either way (see `GroupRestaurantNameSheet` below), not a
/// full restaurant picker.
enum GroupSheetAction: Identifiable {
    case addRecipe(MealSlot)
    case addRestaurant(MealSlot, isOrderIn: Bool)
    case suggestRecipe(MealSlot)
    case suggestRestaurant(MealSlot, isOrderIn: Bool)

    var id: String {
        switch self {
        case .addRecipe(let slot): return "addRecipe-\(slot.rawValue)"
        case .addRestaurant(let slot, let isOrderIn): return "addRestaurant-\(slot.rawValue)-\(isOrderIn)"
        case .suggestRecipe(let slot): return "suggestRecipe-\(slot.rawValue)"
        case .suggestRestaurant(let slot, let isOrderIn): return "suggestRestaurant-\(slot.rawValue)-\(isOrderIn)"
        }
    }
}

/// Builds the actual sheet content for a `GroupSheetAction`, and performs
/// the data mutations (inserting a `.pendingCreate` `GroupPlannedMeal`/
/// `GroupMealSuggestion`) each picker's callback triggers — same
/// local-first-insert-and-dismiss-immediately pattern as every other write
/// in this feature (the real `POST` happens on the next sync; see
/// `GroupSyncService.push`), and the same "declared as its own `View`, not a
/// free function, so its `@Environment` is populated the normal way" reasoning
/// as the personal `MealSheetContent`.
struct GroupMealSheetContent: View {
    let action: GroupSheetAction
    let groupID: String
    let date: Date
    let currentUserID: String?

    @Environment(\.modelContext) private var modelContext

    private var normalizedDate: Date { GroupPlannedMeal.normalize(date) }

    var body: some View {
        switch action {
        case .addRecipe(let slot):
            GroupRecipePickerSheet { id, title in decide(slot: slot, recipeID: id, recipeTitle: title) }
        case .addRestaurant(let slot, let isOrderIn):
            GroupRestaurantNameSheet(isOrderIn: isOrderIn) { name in
                decide(slot: slot, restaurantName: name, isOrderIn: isOrderIn)
            }
        case .suggestRecipe(let slot):
            GroupRecipePickerSheet { id, title in suggest(slot: slot, recipeID: id, recipeTitle: title) }
        case .suggestRestaurant(let slot, let isOrderIn):
            GroupRestaurantNameSheet(isOrderIn: isOrderIn) { name in
                suggest(slot: slot, restaurantName: name, isOrderIn: isOrderIn)
            }
        }
    }

    private func decide(
        slot: MealSlot, recipeID: String? = nil, recipeTitle: String? = nil,
        restaurantName: String? = nil, isOrderIn: Bool = false
    ) {
        guard let currentUserID else { return }
        let meal = GroupPlannedMeal(
            id: GroupPlannedMeal.newLocalPlaceholderID(), groupID: groupID, date: normalizedDate, slot: slot,
            recipeID: recipeID, cachedRecipeTitle: recipeTitle, restaurantName: restaurantName,
            isOrderIn: isOrderIn, decidedByUserID: currentUserID, syncState: .pendingCreate
        )
        modelContext.insert(meal)
        try? modelContext.save()
    }

    private func suggest(
        slot: MealSlot, recipeID: String? = nil, recipeTitle: String? = nil,
        restaurantName: String? = nil, isOrderIn: Bool = false
    ) {
        guard let currentUserID else { return }
        let suggestion = GroupMealSuggestion(
            id: GroupMealSuggestion.newLocalPlaceholderID(), groupID: groupID, date: normalizedDate, slot: slot,
            recipeID: recipeID, cachedRecipeTitle: recipeTitle, restaurantName: restaurantName, isOrderIn: isOrderIn,
            proposedByUserID: currentUserID, myVote: .up, upvoteCount: 1, downvoteCount: 0, syncState: .pendingCreate
        )
        modelContext.insert(suggestion)
        try? modelContext.save()
    }
}

/// A real restaurant *search* — not a bare free-text field — for the group
/// meal plan's "decide"/"suggest" restaurant flow. This used to be a plain
/// `TextField("Restaurant name", text: $name)`: nothing stopped someone from
/// typing gibberish and having it "suggest" a place that doesn't exist,
/// since the field had no connection to any real-world data at all (see
/// this feature's user-reported bug report). Fixed two ways:
///
/// 1. **Live search-as-you-type**, tapping a real result to pick it — same
///    interaction, and the same **Google Places first, `MKLocalSearch`
///    fallback** precedence, as `RestaurantListView`'s own
///    `RestaurantSearchModel.search(_:)` (see that method's own
///    `GooglePlacesService.isConfigured` check): Google's richer text
///    search when it's configured, falling back to Apple's free on-device
///    index only if Google isn't set up or its request fails.
///    `GroupRestaurantSearchModel` below duplicates that precedence rather
///    than reusing `RestaurantSearchModel` wholesale, since that type also
///    builds a `Restaurant` SwiftData row on selection and exposes
///    rating/price/cuisine/photos this screen has no use for — every
///    downstream `restaurantName` here is, and stays, a plain string (see
///    that field's own doc comment: still no backend-side restaurant entity
///    to pick from, and none is needed just to fix the missing search
///    grounding). Reaching into `RestaurantListView.swift` to extract a
///    shared component risked destabilizing a live, in-use personal feature
///    for a dependency shape this screen doesn't fully need; duplicating
///    just the search *call* (not the whole model) keeps that risk at zero
///    while still linking to the real API the user specifically asked for
///    ("the search bar should be linked to the google places api").
/// 2. **A "Your Restaurants" quick-pick**, listing this device's own saved,
///    personal `Restaurant` rows (the same ones `RestaurantListView` shows
///    under "Eating Out") above the live search — user feedback was that
///    "eat out and order in has a search bar and not the options you have
///    from your restaurant list." Tapping one submits its name exactly like
///    a live search result does; nothing here reads or writes the `Restaurant`
///    row itself, so no group-scoped schema is involved.
///
/// **What gets submitted**: a result's/saved restaurant's plain name alone,
/// not "name, address" — every downstream display of `restaurantName`
/// (`GroupPlannedMealRow`'s pill, `GroupSuggestionRow`, `GroupAgendaDayRow`'s
/// one-line slot summary) is a compact, space-constrained label, the same
/// shape a hand-typed name always produced, and an address tacked on would
/// either get silently truncated there or badly overflow a pill sized for a
/// short name. The result list in this sheet still shows the address as a
/// secondary line — enough to tell two same-named places apart before
/// picking one — it just isn't carried into the string that ends up stored.
private struct GroupRestaurantNameSheet: View {
    let isOrderIn: Bool
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// This device's own saved, personal restaurants — see this type's own
    /// doc comment for why they're offered here too, not just live search
    /// results. Unfiltered by `searchText` on purpose: `RestaurantListView`
    /// itself always shows the full "Your Restaurants" list regardless of
    /// whether a search is active, and this sheet matches that precedent
    /// exactly rather than inventing a different rule.
    @Query(sort: \Restaurant.name) private var savedRestaurants: [Restaurant]
    @State private var searchText = ""
    @StateObject private var searchModel = GroupRestaurantSearchModel()
    @StateObject private var locationProvider = UserLocationProvider()

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearchActive {
                    searchResultsSection
                }
                if savedRestaurants.isEmpty && !isSearchActive {
                    Text("Search above to find a place, or save some to Eating Out to see them here.")
                        .foregroundStyle(.secondary)
                } else if !savedRestaurants.isEmpty {
                    savedRestaurantsSection
                }
            }
            .searchable(text: $searchText, prompt: "Search for a restaurant")
            .onChange(of: searchText) { _, newValue in
                searchModel.search(newValue)
            }
            .onAppear {
                locationProvider.requestIfNeeded()
            }
            .onChange(of: locationProvider.coordinate) { _, newValue in
                searchModel.userCoordinate = newValue
            }
            .navigationTitle(isOrderIn ? "Order In" : "Eat Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var searchResultsSection: some View {
        Section {
            if searchModel.isSearching && searchModel.results.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage = searchModel.errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else if searchModel.results.isEmpty {
                Text("No matches found.").foregroundStyle(.secondary)
            } else {
                ForEach(searchModel.results) { result in
                    Button {
                        onSubmit(result.name)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name).foregroundStyle(.primary)
                            if let address = result.address {
                                Text(address)
                                    .font(.brandCaption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Search Results")
        }
    }

    private var savedRestaurantsSection: some View {
        Section {
            ForEach(savedRestaurants) { restaurant in
                Button {
                    onSubmit(restaurant.name)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(restaurant.name).foregroundStyle(.primary)
                            if let address = restaurant.address {
                                Text(address)
                                    .font(.brandCaption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if restaurant.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.brandCaption)
                        }
                    }
                }
            }
        } header: {
            Text("Your Restaurants")
        }
    }
}

/// `RestaurantSearchModel`'s exact search precedence
/// (`GooglePlacesService.search` first, `MKLocalSearch` fallback), just
/// without the pieces `GroupRestaurantNameSheet` doesn't need — see that
/// type's own doc comment for why this is a deliberate, small duplication
/// rather than a shared abstraction with the personal, `Restaurant`-backed
/// model. Same 300ms debounce as `RestaurantSearchModel.search`, for the
/// same "don't fire a network search on every keystroke" reason.
@MainActor
private final class GroupRestaurantSearchModel: ObservableObject {
    struct Result: Identifiable {
        let id: String
        let name: String
        let address: String?
    }

    @Published var results: [Result] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    /// Set by the view once location access resolves — biases MapKit's
    /// ranking toward nearby results; `nil` (denied, not yet answered, or
    /// simply unavailable) just falls back to unbiased results, same as
    /// `RestaurantSearchModel.userCoordinate`.
    var userCoordinate: CLLocationCoordinate2D?

    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        let coordinate = userCoordinate
        searchTask = Task {
            // Small debounce so a search isn't fired on every keystroke —
            // same value as `RestaurantSearchModel.search`.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isSearching = true
            errorMessage = nil
            defer { isSearching = false }

            // Same precedence as `RestaurantSearchModel.search`: Google's
            // richer text search first when it's configured, falling
            // through to the free MapKit path either when Google isn't set
            // up at all, or if the request itself fails for any reason
            // (rather than dead-ending the search on a bad server moment).
            if GooglePlacesService.isConfigured {
                do {
                    let places = try await GooglePlacesService.search(trimmed, near: coordinate)
                    guard !Task.isCancelled else { return }
                    results = places.map { Result(id: $0.id, name: $0.name, address: $0.address) }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // Fall through to MapKit below.
                }
            }

            await searchWithMapKit(trimmed, near: coordinate)
        }
    }

    private func searchWithMapKit(_ query: String, near coordinate: CLLocationCoordinate2D?) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if let coordinate {
            // A ~50km region biases MapKit's own ranking toward this
            // area — without it MapKit ranks purely by name/relevance,
            // same reasoning as `RestaurantSearchModel.searchWithMapKit`.
            request.region = MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            let items = coordinate.map { userLocation in
                response.mapItems.sorted {
                    distance(from: userLocation, to: $0.placemark.coordinate)
                        < distance(from: userLocation, to: $1.placemark.coordinate)
                }
            } ?? response.mapItems
            results = items.enumerated().map { index, item in
                Result(
                    id: "mapkit-\(index)-\(item.name ?? "")",
                    name: item.name ?? "Unknown",
                    address: item.placemark.title
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = "Couldn't search right now — check your connection."
        }
    }

    private func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }
}

/// Picks a recipe from everything the caller can legally plan/suggest with
/// — their own recipe-library recipes, plus everything shared with them
/// (directly or via any group) — exactly the same owner/direct-share/
/// shared-group visibility check `routes/groupMealPlan.js`'s
/// `recipeVisibleToUser` enforces server-side (see that function's own doc
/// comment), so this picker can never offer a recipe the backend would
/// reject with a `400`. Deduped by recipe id: `GET /recipe-library/shared-with-me`
/// returns one entry PER SHARE (see `SharedRecipeEntry`'s own doc comment),
/// so the same recipe shared two different ways would otherwise appear
/// twice here.
private struct GroupRecipePickerSheet: View {
    let onPick: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recipes: [(id: String, title: String)] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filteredRecipes: [(id: String, title: String)] {
        guard !searchText.isEmpty else { return recipes }
        return recipes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && recipes.isEmpty {
                    ProgressView()
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                } else if recipes.isEmpty {
                    ContentUnavailableView(
                        "No Recipes Yet",
                        systemImage: "book",
                        description: Text("Only recipes you own, or that have been shared with you, can be planned here. Share one from Recipes first.")
                    )
                } else {
                    ForEach(filteredRecipes, id: \.id) { recipe in
                        Button {
                            onPick(recipe.id, recipe.title)
                            dismiss()
                        } label: {
                            Text(recipe.title).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $searchText)
            .navigationTitle("Choose a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let mine = AccountsAPIClient.getMyRecipes()
            async let shared = AccountsAPIClient.getSharedRecipes()
            let (mineResult, sharedResult) = try await (mine, shared)
            var byID: [String: String] = [:]
            for recipe in mineResult { byID[recipe.id] = recipe.title }
            for entry in sharedResult { byID[entry.recipeID] = entry.title }
            recipes = byID.map { (id: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
