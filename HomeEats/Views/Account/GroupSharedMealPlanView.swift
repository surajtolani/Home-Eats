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
/// decided-meal row and vote-count/"Use This" suggestion row. Where this
/// screen has since diverged from the personal reference views: there's a
/// single "Add a Meal" button for the whole day (`GroupDaySlotsView
/// .addMealSection`), not one per slot, opening `GroupAddMealSheet` (three
/// side-by-side wheel pickers — slot/kind/add-or-suggest — plus a live
/// recipe list or restaurant search underneath, itself offering "Recommend
/// a Meal"/"Ask for a Restaurant" alongside that search), not the personal
/// screens' bank of individual per-kind buttons; see that sheet's own doc
/// comment for why. The actual per-slot content lives in `GroupDaySlotsView`
/// below, embedded inline here (Calendar mode) and pushed via
/// `GroupDayDetailView` (Weekly mode's tap target) — same split, and the
/// same reasoning for it, as the personal `DaySlotsView`/`DayDetailView`.
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
/// exactly (see routes/groupMealPlan.js) — a `MANAGER` can decide a meal
/// directly ("Add" in `GroupAddMealSheet`'s third wheel) and sees "Use
/// This" (adopts a suggestion); a `PARTICIPANT` only ever gets "Suggest" in
/// that same third wheel (a single-row wheel — see
/// `GroupAddMealSheet.actionChoices`) and the vote buttons, same "never
/// offer an action that would just 403" standard the rest of this feature
/// holds to.
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
    /// Which recipe/restaurant a tap-to-navigate row should push to, if any
    /// — same "owned by whichever screen embeds `GroupDaySlotsView`, not by
    /// that view itself" reasoning as `activeSheet` above, and the same
    /// "attach `.navigationDestination(item:)` to the `List`/`Form` root,
    /// never to row content" fix for the identical List-row race that
    /// modifier's own doc comment describes. This replaced an earlier
    /// design where `GroupPlanLinkableRow` embedded a hidden `NavigationLink`
    /// directly inside each row — direct user report: "Use This" and the
    /// vote buttons, sitting in the very same row as that hidden link, could
    /// fire the link's navigation instead of their own action on tap. A
    /// `NavigationLink` anywhere inside a `List` row — even one with an
    /// explicit small `.frame` — makes UIKit treat the WHOLE row/cell as a
    /// single navigable tap target underneath the individually-hit-tested
    /// `Button`s layered on top of it, a well-known SwiftUI/`List`
    /// ambiguity that no amount of `.buttonStyle(.plain)` reliably
    /// resolves. Routing navigation through this state var instead — set by
    /// a plain `.onTapGesture` on just the tappable part of a row, read by
    /// one `.navigationDestination(item:)` outside any row content —
    /// sidesteps the ambiguity entirely: there is no `NavigationLink` in
    /// row content anywhere anymore for the row's real `Button`s to
    /// contend with.
    @State private var pushedTarget: GroupPlanNavigationTarget?

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
        .refreshable {
            // Also re-fetch the group itself, not just item sync — a role
            // change (promote/demote) only lands here, and without this a
            // pull-to-refresh wouldn't pick it up either.
            await loadGroup()
            await runSync()
        }
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
                // `spacing: 8`/`.padding(.vertical, 4)` — tighter than this
                // block's original 16/8. Direct user feedback: the month
                // grid ate up too much vertical height before the day panel
                // even started. See `GroupDayCell`/`monthGrid` below for the
                // matching per-cell tightening (smaller day circles, less
                // row spacing) that does the rest of the work.
                VStack(spacing: 8) {
                    monthHeader
                    legend
                    weekdayHeaderRow
                    monthGrid
                }
                .padding(.vertical, 4)
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
                activeSheet: $activeSheet, pushedTarget: $pushedTarget,
                // Calendar mode only — swiping anywhere in the day panel
                // (not just `selectedDayHeader`'s own row) moves between
                // days here, same gesture, just reachable from every row.
                // `GroupDayDetailView`'s pushed single-day screen below
                // passes a no-op instead — see its own comment.
                onSwipeChangeDay: moveSelectedDate,
                onLocalWrite: { Task { await runSync() } },
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
            GroupMealSheetContent(
                action: action, groupID: groupID, date: selectedDate,
                currentUserID: accountSession.currentUser?.id, isManager: isManager,
                groupDefaultLocationText: group?.defaultLocationText
            )
        }
        // Same "attached to the List root, not to row content" reasoning as
        // `.sheet(item:)` just above — see `pushedTarget`'s own doc comment
        // (on `GroupSharedMealPlanView`) and `GroupPlanLinkableRow`'s for why
        // this replaced an in-row `NavigationLink`.
        .navigationDestination(item: $pushedTarget) { target in
            GroupPlanDestinationView(target: target)
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
        // `spacing: 4`, not 6 — part of the same overall height-tightening
        // as `GroupDayCell`'s own smaller circle/`minHeight` below.
        return LazyVGrid(columns: columns, spacing: 4) {
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
                    // User feedback: "under weekly view, please delete the
                    // arrows on the right - since you can click on the
                    // actual day and it goes to the same place, cleaner
                    // layout." SwiftUI has no modifier to hide just a
                    // `NavigationLink`'s chevron (there's no
                    // `navigationLinkIndicatorVisibility` API) — the actual
                    // way to drop it is to keep the link itself invisible
                    // and hit-testable via `.opacity(0)` (unlike `.hidden()`,
                    // this doesn't remove it from hit-testing) layered under
                    // the real, chevron-free row content in a `ZStack`. Tapping
                    // anywhere on the row still triggers the same push to
                    // `GroupDayDetailView` as before.
                    ZStack {
                        NavigationLink {
                            GroupDayDetailView(
                                groupID: groupID, date: day, isManager: isManager,
                                currentUserID: accountSession.currentUser?.id, group: group, isKnownOffline: isKnownOffline,
                                onLocalWrite: { Task { await runSync() } },
                                onError: { message in actionErrorMessage = message }
                            )
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)

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
    }

    // MARK: - Shared helpers

    // Real, confirmed bug: the month grid's dots and the weekly agenda's
    // per-day counts (both call these two functions) could disagree with
    // what the day panel underneath actually shows — a day with a dot
    // opening to nothing, or a day with real content showing no dot.
    // Root cause: `GroupPlannedMeal.normalize`/`GroupMealSuggestion`'s
    // stored `date` is anchored to a fixed UTC calendar (see that
    // function's own doc comment — deliberately device-independent, fixing
    // an earlier cross-device date-shift bug), but `date` here was always
    // a raw `Calendar.current`-based grid/agenda day, compared directly via
    // `.isSameDay(as:)` (itself `Calendar.current`-based) with no
    // normalization step in between. For any negative-UTC-offset device —
    // this household included — UTC midnight of a given day falls on the
    // *previous* local calendar day, so every single populated day's dot
    // silently landed one cell to the left of its actual content. Only
    // ever visible on days that actually have something planned/suggested,
    // which is exactly the "some days have dots but nothing shows, other
    // days show content with no dot" symptom reported. `GroupDaySlotsView
    // .meals(for:)`/`.suggestions(for:)` already route their own date
    // through `GroupPlannedMeal.normalize` before comparing — this just
    // brings these two in line with that same, already-correct pattern.
    private func meals(on date: Date) -> [GroupPlannedMeal] {
        let normalizedDate = GroupPlannedMeal.normalize(date)
        return visiblePlannedMeals.filter { $0.date.isSameDay(as: normalizedDate) }
    }

    private func suggestionCount(on date: Date) -> Int {
        let normalizedDate = GroupPlannedMeal.normalize(date)
        return visibleSuggestions.filter { $0.date.isSameDay(as: normalizedDate) }.count
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
            // `runSync()` only syncs planned meals — group membership and
            // roles live in `group` (fetched by `loadGroup()`), which
            // otherwise never refreshes after the initial `.task` load. A
            // promoted/demoted member would stay stuck at their old
            // permissions on their own device until they force-quit the app.
            await loadGroup()
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
        // `spacing: 2`, a 26pt circle, and `minHeight: 36` — down from
        // 4/30/48 — is the bulk of this screen's calendar-height tightening
        // (six-ish rows × ~12-14pt saved each adds up fast); direct user
        // feedback that the month grid "isn't so spread out" was mostly
        // about this cell's own height, not the spacing around it.
        VStack(spacing: 2) {
            Text(dayNumber)
                .font(.brandSubheadline.weight(isToday ? .bold : .regular))
                .frame(width: 26, height: 26)
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
        .frame(maxWidth: .infinity, minHeight: 36)
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
                                // Direct user request: a label next to the
                                // meal/restaurant name saying which slot
                                // it's for — the icon alone only says HOW
                                // (cooked/dine out/order in), not WHEN.
                                Text(slot.displayName)
                                    .font(.brandCaption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
    /// Same reasoning as `GroupSharedMealPlanView.pushedTarget` — owned by
    /// this pushed screen's own `Form` root instead.
    @State private var pushedTarget: GroupPlanNavigationTarget?

    var body: some View {
        Form {
            GroupDaySlotsView(
                groupID: groupID, date: date, isManager: isManager, currentUserID: currentUserID,
                group: group, isKnownOffline: isKnownOffline, activeSheet: $activeSheet,
                pushedTarget: $pushedTarget,
                // No day-to-day date to swipe to from here — this screen is
                // pushed for one fixed `date`, unlike the Calendar mode's
                // inline panel (`GroupSharedMealPlanView.moveSelectedDate`)
                // which owns a `selectedDate` this could reassign.
                onSwipeChangeDay: { _ in },
                onLocalWrite: onLocalWrite, onError: onError
            )
        }
        .navigationTitle(date.formatted(Date.weekdayFull))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { action in
            GroupMealSheetContent(
                action: action, groupID: groupID, date: date, currentUserID: currentUserID, isManager: isManager,
                groupDefaultLocationText: group?.defaultLocationText
            )
        }
        .navigationDestination(item: $pushedTarget) { target in
            GroupPlanDestinationView(target: target)
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
    /// Same "owned by whichever screen embeds this view" reasoning as
    /// `activeSheet` — see `GroupSharedMealPlanView.pushedTarget`'s own doc
    /// comment for the full "why a `@Binding` here, not a hidden
    /// `NavigationLink` in row content" story.
    @Binding var pushedTarget: GroupPlanNavigationTarget?
    /// Fired on a horizontal swipe on one of this view's rows, with `-1`/
    /// `+1` for the direction — the Calendar mode's inline day panel wires
    /// this to `GroupSharedMealPlanView.moveSelectedDate`; the pushed
    /// `GroupDayDetailView` (a fixed single day, nothing to swipe to) passes
    /// a no-op instead. Applied per-row (via `.daySwipeGesture(_:)` below,
    /// only on rows without their own `.swipeActions` — see that modifier's
    /// own doc comment for why) rather than once to some wrapping
    /// container — `List`/`Section` backs each row with its own separate
    /// cell, so a gesture attached anywhere but the individual row content
    /// would only ever fire for whichever one row happened to receive it,
    /// same reasoning as why `selectedDayHeader`'s original swipe gesture
    /// had to live on that row itself rather than on the `List` as a whole.
    let onSwipeChangeDay: (Int) -> Void
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
    /// Set right after `adopt(_:)` succeeds, only when that slot still has
    /// other suggestions left over — drives the "Remove all other options?"
    /// confirmation below. Direct user request: "If I select an item from
    /// the list of things to vote, it should create a prompt to 'Remove all
    /// other options?' so the other options for that meal is no longer
    /// there." `nil` both before any adopt and after the dialog is dismissed
    /// either way.
    @State private var pendingSlotCleanup: MealSlot?
    /// Which slot's "View Votes" sheet is open, if any — see
    /// `slotSection(_:)`'s header for where this gets set, and
    /// `SlotVotesSheet` below for what it shows.
    @State private var votesSheetSlot: MealSlot?

    init(
        groupID: String, date: Date, isManager: Bool, currentUserID: String?, group: GroupDetail?,
        isKnownOffline: Bool, activeSheet: Binding<GroupSheetAction?>, pushedTarget: Binding<GroupPlanNavigationTarget?>,
        onSwipeChangeDay: @escaping (Int) -> Void,
        onLocalWrite: @escaping () -> Void, onError: @escaping (String) -> Void
    ) {
        self.groupID = groupID
        self.date = date
        self.isManager = isManager
        self.currentUserID = currentUserID
        self.group = group
        self.isKnownOffline = isKnownOffline
        self._activeSheet = activeSheet
        self._pushedTarget = pushedTarget
        self.onSwipeChangeDay = onSwipeChangeDay
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
            // Stable proposal order (oldest first), NOT live net score —
            // direct, confirmed bug report: sorting by a score that changes
            // the instant someone votes means the list itself reorders on
            // every tap, so the row the user's finger is still over can
            // become a *different* suggestion by the time the tap lands —
            // "I vote thumbs-up on the 2nd option and it activates the
            // 1st one instead" (really: voting on the 2nd one correctly
            // registered, but immediately moved it to a new position,
            // sliding the untouched 1st one into the row the user was
            // still looking at). `createdAt` never changes as a side effect
            // of voting, so the list order stays put while someone
            // actually taps through several options in a row.
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func memberName(_ userID: String) -> String {
        group?.members.first(where: { $0.id == userID })?.displayNameOrPhoneNumber ?? "Someone"
    }

    /// One single "Add Another Meal" entry point for the whole day, not one
    /// per slot — direct user feedback: `GroupAddMealSheet`'s own first
    /// wheel already lets you pick breakfast/lunch/dinner/other, so a
    /// separate button in every slot section just to reach the same sheet
    /// was redundant with a picker that already exists right there once
    /// it's open. Shown whenever the day already has at least one planned
    /// meal or suggestion (`emptyDayState` below is the day's *own* "Add a
    /// Meal" entry point when it has nothing yet, so this one only needs to
    /// cover "add another" — hence the different label) — a slot can hold
    /// more than one decided meal, so there's always a reason to keep
    /// offering it once the day isn't completely empty. Centered, with its
    /// own pill background — direct user request, so it reads as a clear
    /// standalone action rather than a plain text row blending into the
    /// slot sections around it.
    private var addMealSection: some View {
        Section {
            HStack {
                Spacer(minLength: 0)
                Button {
                    activeSheet = .pickMeal(defaultSlotForAdd)
                } label: {
                    Label("Add Another Meal", systemImage: "plus.circle.fill")
                        .font(.brandSubheadline.bold())
                        .foregroundStyle(Color.brandForest)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.brandForest.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowSeparator(.hidden)
            .daySwipeGesture(onSwipeChangeDay)
        }
    }

    /// The slot `Add a Meal`'s wheel opens preselected to — the first slot
    /// with nothing planned or suggested yet for the day, or `.breakfast` if
    /// every slot already has something (which is also the case for a
    /// completely empty day). Purely a starting point for the wheel (freely
    /// changeable there) — see `addMealSection`'s own doc comment for why
    /// there's only ever this one entry point now, instead of one per slot.
    private var defaultSlotForAdd: MealSlot {
        MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }
            .first { meals(for: $0).isEmpty && suggestions(for: $0).isEmpty } ?? .breakfast
    }

    /// Whether the WHOLE day has nothing planned or suggested in any slot —
    /// drives the choice between `emptyDayState` (below) and the normal
    /// "Add a Meal" + populated-slots layout. Direct user feedback: don't
    /// assume every day gets a Breakfast/Lunch/Dinner/Other plan — a
    /// completely blank day showing four empty section headers in a row
    /// read as "you're behind on planning four things," not "nothing's
    /// here yet." A single friendly empty state reads as the latter.
    private var isDayEmpty: Bool {
        MealSlot.allCases.allSatisfy { meals(for: $0).isEmpty && suggestions(for: $0).isEmpty }
    }

    /// Only the slots that actually have something in them, in display
    /// order — the other half of the same feedback `isDayEmpty` addresses:
    /// once the day has at least one meal, the *other*, still-empty slots
    /// still shouldn't render their own blank "Breakfast" / "Lunch" section
    /// with nothing under it. A slot's header (and the section itself) only
    /// ever appears once it has real content.
    private var populatedSlots: [MealSlot] {
        MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }
            .filter { !meals(for: $0).isEmpty || !suggestions(for: $0).isEmpty }
    }

    var body: some View {
        if isDayEmpty {
            emptyDayState
        } else {
            addMealSection
            ForEach(populatedSlots) { slot in
                slotSection(slot)
            }
            .confirmationDialog(
                "Remove the other options for this meal?",
                isPresented: Binding(get: { pendingSlotCleanup != nil }, set: { if !$0 { pendingSlotCleanup = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove Other Options", role: .destructive) {
                    if let slot = pendingSlotCleanup { removeOtherSuggestions(for: slot) }
                    pendingSlotCleanup = nil
                }
                Button("Keep Them", role: .cancel) { pendingSlotCleanup = nil }
            } message: {
                Text("This meal is decided now. The other suggested options for it can be removed so they're no longer up for a vote.")
            }
            .sheet(item: $votesSheetSlot) { slot in
                SlotVotesSheet(slotName: slot.displayName, suggestions: suggestions(for: slot))
            }
        }
    }

    /// The whole day's empty state — a heart-over-a-bowl illustration, "No
    /// meals added yet," a one-line hint, and this day's own big "Add a
    /// Meal" button — shown instead of `addMealSection` + any slot sections
    /// while `isDayEmpty` holds. Still one `Section` (this content is always
    /// embedded in a `List`/`Form`, never on its own), and still carries the
    /// same `.daySwipeGesture` `addMealSection`'s row does, so swiping to
    /// the next day works identically on a blank day as on a populated one.
    private var emptyDayState: some View {
        Section {
            VStack(spacing: 14) {
                ZStack(alignment: .top) {
                    Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Color.brandForest.opacity(0.22))
                        .padding(.top, 18)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.brandForest.opacity(0.55))
                }

                VStack(spacing: 4) {
                    Text("No meals added yet")
                        .font(.brandHeadline.bold())
                    Text("Plan a meal, find a recipe, or discover a great restaurant.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    activeSheet = .pickMeal(defaultSlotForAdd)
                } label: {
                    Label("Add a Meal", systemImage: "plus")
                        .font(.brandSubheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandForest)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 22)
            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
            .listRowSeparator(.hidden)
            .daySwipeGesture(onSwipeChangeDay)
        }
    }

    @ViewBuilder
    private func slotSection(_ slot: MealSlot) -> some View {
        // Whether ANY row in this slot is still mid-sync — drives a single
        // pending icon on the slot's own header instead of one per row (see
        // the `header:` below). Direct user report: a per-row icon that
        // appears/disappears as a vote goes out (usually well under a
        // second) shifted that row's own content enough to wrap its title
        // onto a different line. A slot only ever has a handful of rows, so
        // one shared indicator for the whole slot loses no real information
        // — "something in Breakfast hasn't synced yet" is just as useful as
        // "this specific row hasn't" for what this icon is for — while
        // moving it somewhere (the header) that was never part of any row's
        // own text layout to begin with means it can never distort one
        // again, regardless of how often it flickers.
        let hasPendingInSlot = meals(for: slot).contains { $0.syncState != .synced }
            || suggestions(for: slot).contains { $0.syncState != .synced }

        Section {
            // Neither of these two rows carries `.daySwipeGesture` — both
            // have their own `.swipeActions(edge: .trailing)` (Remove, on
            // `GroupPlannedMealRow`/`GroupSuggestionRow` below), which is a
            // horizontal drag on this exact same row driven by `List`'s own
            // UIKit-level pan recognizer, a different layer than SwiftUI's
            // `Gesture` system — `.simultaneousGesture` only guarantees
            // non-exclusivity with *other SwiftUI gestures*, not with that
            // recognizer. Adding the day-swipe gesture here too risked the
            // exact same leftward drag that reveals "Remove" also being
            // read as "go to the next day," fighting or double-firing
            // unpredictably. `addMealSection`'s own row above (the one
            // place this file still applies `.daySwipeGesture`) has no
            // `.swipeActions` at all, so it's a safe place for the gesture
            // to live without that particular conflict.
            ForEach(meals(for: slot)) { meal in
                GroupPlannedMealRow(
                    meal: meal, memberName: memberName(meal.decidedByUserID), isManager: isManager,
                    pushedTarget: $pushedTarget,
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
                    pushedTarget: $pushedTarget,
                    onVote: { direction in vote(suggestion, direction: direction) },
                    onAdopt: { Task { await adopt(suggestion) } },
                    onRemove: { withdrawSuggestion(suggestion) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }
        } header: {
            // Direct user request: make a slot's own header ("Breakfast,"
            // "Dinner," etc.) more pronounced once it actually has
            // something under it — a plain `Section` header otherwise
            // renders small, uppercase, and secondary-gray by default,
            // which read as too quiet once this row only shows up for
            // slots with real content (see `populatedSlots` above).
            // `.textCase(nil)` cancels that automatic all-caps transform;
            // the explicit bold, larger, primary-colored font overrides the
            // rest.
            HStack(spacing: 4) {
                Label(slot.displayName, systemImage: slot.symbolName)
                    .font(.brandSubheadline.bold())
                    .foregroundStyle(Color.primary)
                if hasPendingInSlot {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.brandCaption2)
                        .foregroundStyle(.secondary)
                        .help("Not synced yet")
                }
                // Direct user request, replacing the earlier long-press
                // affordance on each vote capsule — confirmed confusing on
                // its own two counts: not discoverable, and (once found)
                // gave no visual indication of which direction's voters a
                // given long-press was even showing. "next to the meal
                // type... have an icon show up (only if there are
                // suggestions) that says 'View Votes'." Only shown when
                // this slot actually has suggestions — a slot with only
                // already-decided meals has no votes to show.
                if !suggestions(for: slot).isEmpty {
                    Button {
                        votesSheetSlot = slot
                    } label: {
                        Label("View Votes", systemImage: "checklist")
                            .font(.brandCaption2.bold())
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandForest)
                }
            }
            .textCase(nil)
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
    ///
    /// Adopting only ever turns THIS ONE suggestion into a decided meal —
    /// it never touches any other suggestion still sitting in the same
    /// slot, competing for the same vote. Once this succeeds, `suggestions
    /// (for: slot)` (re-evaluated fresh here, after the re-pull inside
    /// `adoptSuggestion` already updated the local store) is checked for
    /// exactly that leftover case: if anything's still there, this queues
    /// up the "Remove all other options?" confirmation (`pendingSlotCleanup`)
    /// rather than silently leaving now-moot suggestions up for a vote —
    /// direct user request (see that property's own doc comment).
    private func adopt(_ suggestion: GroupMealSuggestion) async {
        let slot = suggestion.slot
        do {
            try await GroupSyncService.adoptSuggestion(groupID: groupID, suggestionID: suggestion.id, modelContext: modelContext)
            if !suggestions(for: slot).isEmpty {
                pendingSlotCleanup = slot
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Withdraws every remaining suggestion in `slot` (for `date`, this
    /// view's own scope) — the "Remove Other Options" action on the dialog
    /// `pendingSlotCleanup` drives. Reuses `withdrawSuggestion` one row at a
    /// time (the same offline-queued delete a manual swipe-to-remove already
    /// goes through), rather than a bespoke bulk-delete path — there's no
    /// dedicated "clear a slot's suggestions" backend endpoint, and this
    /// list is never more than a handful of rows.
    private func removeOtherSuggestions(for slot: MealSlot) {
        for suggestion in suggestions(for: slot) {
            withdrawSuggestion(suggestion)
        }
    }
}

/// Same horizontal-swipe-changes-day gesture as `selectedDayHeader`'s own,
/// factored out so more of `GroupDaySlotsView.slotSection`'s rows can carry
/// it too — direct user request ("can you add functionality to swipe left
/// and right to move from one day to another?"): the header's own small
/// swipe target wasn't the whole story, since most of the day panel's
/// actual height is these rows, not the header. `.simultaneousGesture`, not
/// `.gesture` — a row this is applied to still sits inside a scrollable
/// `List`, and a plain `.gesture` would claim every touch that starts here
/// exclusively, including an attempt to scroll or a `Button` tap starting
/// from this exact row. `minimumDistance: 20` plus the horizontal-vs-
/// vertical check below is what lets a normal tap/scroll pass through
/// untouched — only a drag that's both long enough and clearly more
/// horizontal than vertical actually changes the day.
///
/// **Deliberately NOT applied to every row** — only to rows with no
/// `.swipeActions` of their own (see `slotSection`'s own comment above its
/// `ForEach`s). `.swipeActions` reveal is driven by `List`'s own UIKit-level
/// pan recognizer, a different layer `.simultaneousGesture` has no
/// visibility into — it can only guarantee non-exclusivity with *other
/// SwiftUI gestures* in the same view, not with that recognizer. Putting
/// this gesture on a row that also has `.swipeActions` risked the same
/// leftward drag that reveals "Remove" also reading as "go to the next
/// day," fighting or double-firing unpredictably; narrowing this to
/// swipe-action-free rows avoids that class of conflict entirely rather
/// than trying to tune distance/velocity thresholds against a recognizer
/// this code can't actually negotiate with.
private extension View {
    func daySwipeGesture(_ onSwipe: @escaping (Int) -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    onSwipe(value.translation.width < 0 ? 1 : -1)
                }
        )
    }
}

// MARK: - Tap-to-navigate destination

/// Identifies which recipe/restaurant a tap-to-navigate row should push to
/// — see `GroupSharedMealPlanView.pushedTarget`'s own doc comment for why
/// this drives a `.navigationDestination(item:)` at the List/Form root
/// instead of an in-row `NavigationLink`. Exactly one of
/// `recipeID`/`restaurantName` is ever set (mirrors the backend's own
/// "exactly one of recipeId/restaurantName" rule — see `GroupPlannedMeal
/// .recipeID`'s own doc comment).
///
/// `Hashable`, not just `Equatable` — `.navigationDestination(item:)`'s
/// binding type requires `Hashable` (it's used as a `NavigationPath`
/// element under the hood), and every stored property here is already
/// `Hashable` (`String?`), so Swift synthesizes the conformance for free.
struct GroupPlanNavigationTarget: Identifiable, Hashable {
    let recipeID: String?
    let cachedRecipeTitle: String?
    let restaurantName: String?

    var id: String {
        if let recipeID { return "recipe-\(recipeID)" }
        if let restaurantName { return "restaurant-\(restaurantName)" }
        return "none"
    }
}

/// Resolves and shows the actual destination for a `GroupPlanNavigationTarget`
/// — moved out of what used to be `GroupPlanLinkableRow`'s own `destination`
/// computed property (see `pushedTarget`'s doc comment for why that type no
/// longer embeds a `NavigationLink`/`@Query` of its own at all); this is now
/// the one place that logic lives, built fresh by
/// `.navigationDestination(item:)` only once a tap actually sets a target,
/// rather than speculatively for every row up front.
///
/// **Recipe destination**: an already-saved local `Recipe` (found by
/// `backendRecipeID`, the same lookup `GroupSyncService.resolveRecipeTitle`
/// already does) if there is one — straight to the real, editable
/// `RecipeDetailView`, not a read-only preview, when the viewer already has
/// their own copy. Otherwise `GroupRecipePreviewView`, which fetches the
/// recipe straight from the backend (it may belong to another group member
/// entirely, not the viewer).
///
/// **Restaurant destination**: same idea, but matched by name (free text —
/// see `GroupPlannedMeal.restaurantName`'s own doc comment, there's no id to
/// match by) against the viewer's local `Restaurant` library, case-
/// insensitively. Otherwise `GroupRestaurantPreviewView`, which runs a live
/// search for that name.
struct GroupPlanDestinationView: View {
    let target: GroupPlanNavigationTarget

    @Query private var matchingRecipes: [Recipe]
    @Query private var allRestaurants: [Restaurant]

    init(target: GroupPlanNavigationTarget) {
        self.target = target
        // Same captured-local-constant, typed-Optional-comparison
        // `#Predicate` caution as `GroupSyncService.resolveRecipeTitle` —
        // see its own comment.
        let targetRecipeID: String? = target.recipeID
        _matchingRecipes = Query(filter: #Predicate<Recipe> { $0.backendRecipeID == targetRecipeID })
        _allRestaurants = Query()
    }

    /// Filtered client-side, not via `#Predicate` — see the identical note
    /// this replaced on the old `GroupPlanLinkableRow.matchedRestaurant`.
    private var matchedRestaurant: Restaurant? {
        guard let restaurantName = target.restaurantName else { return nil }
        return allRestaurants.first { $0.name.caseInsensitiveCompare(restaurantName) == .orderedSame }
    }

    var body: some View {
        if let recipeID = target.recipeID {
            if let localRecipe = matchingRecipes.first {
                RecipeDetailView(recipe: localRecipe)
            } else {
                GroupRecipePreviewView(recipeID: recipeID, cachedTitle: target.cachedRecipeTitle)
            }
        } else if let restaurantName = target.restaurantName {
            if let matchedRestaurant {
                RestaurantDetailView(restaurant: matchedRestaurant)
            } else {
                GroupRestaurantPreviewView(name: restaurantName)
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - Rows

/// Wraps `content` so tapping it navigates to whatever this meal/suggestion
/// actually refers to — direct user request ("why aren't we able to click
/// on it to go into the recipe... same issue with restaurant, we should be
/// able to click in it and it takes us to that restaurant page"). Exactly
/// one of `recipeID`/`restaurantName` is ever set (mirrors the backend's own
/// "exactly one of recipeId/restaurantName" rule — see `GroupPlannedMeal
/// .recipeID`'s own doc comment); this is a no-op (no tap gesture at all)
/// on the — shouldn't-happen-in-practice — case neither is set.
///
/// A plain `.onTapGesture` setting `pushedTarget`, NOT a hidden
/// `NavigationLink` behind `content` (what this used to be) — direct user
/// report: "Use This"/the vote buttons, `GroupSuggestionRow`'s real
/// `Button`s sitting in the very same row as that hidden link, could fire
/// its navigation instead of their own action on tap. A `NavigationLink`
/// anywhere inside a `List` row — even one with an explicit small `.frame`
/// — makes UIKit treat the whole row/cell as a single navigable tap target
/// underneath whatever `Button`s are layered on top of it, a well-known
/// SwiftUI/`List` ambiguity `.buttonStyle(.plain)` doesn't reliably
/// resolve. Setting a plain `@Binding` from an `.onTapGesture` instead, read
/// by one `.navigationDestination(item:)` outside any row content (see
/// `GroupSharedMealPlanView.pushedTarget`'s own doc comment), has no
/// `NavigationLink` in row content anywhere left for a real `Button` to
/// contend with — the destination-resolving logic itself now lives in
/// `GroupPlanDestinationView`, built only once a tap actually sets a target.
private struct GroupPlanLinkableRow<RowContent: View>: View {
    let recipeID: String?
    let cachedRecipeTitle: String?
    let restaurantName: String?
    @Binding var pushedTarget: GroupPlanNavigationTarget?
    // Plain, no `@ViewBuilder` here — the builder transform already
    // happened on the `init` parameter below (the standard place for it on
    // a stored closure property like this); this is just where the already-
    // built closure lives.
    let content: () -> RowContent

    init(
        recipeID: String?, cachedRecipeTitle: String?, restaurantName: String?,
        pushedTarget: Binding<GroupPlanNavigationTarget?>,
        @ViewBuilder content: @escaping () -> RowContent
    ) {
        self.recipeID = recipeID
        self.cachedRecipeTitle = cachedRecipeTitle
        self.restaurantName = restaurantName
        self._pushedTarget = pushedTarget
        self.content = content
    }

    var body: some View {
        if recipeID == nil && restaurantName == nil {
            content()
        } else {
            content()
                .contentShape(Rectangle())
                .onTapGesture {
                    pushedTarget = GroupPlanNavigationTarget(
                        recipeID: recipeID, cachedRecipeTitle: cachedRecipeTitle, restaurantName: restaurantName
                    )
                }
        }
    }
}

private struct GroupPlannedMealRow: View {
    let meal: GroupPlannedMeal
    let memberName: String
    let isManager: Bool
    @Binding var pushedTarget: GroupPlanNavigationTarget?
    let onRemove: () -> Void

    /// Only queried to opportunistically resolve a real recipe photo for
    /// `thumbnail` below — see that property's own doc comment. Any given
    /// day panel only ever has a handful of these rows on screen at once,
    /// so one small unfiltered `@Query` per row costs nothing real.
    @Query private var allRecipes: [Recipe]

    /// Same icon+color convention as the personal `PlannedMealRow` — a
    /// recipe, an eat-out plan, and an order-in plan all read distinctly at
    /// a glance here too, and it's the same palette as the calendar's own
    /// legend/status dots. Still used as `thumbnail`'s own fallback
    /// placeholder below, even now that this row is a `MediaTileRow`.
    private var iconName: String {
        if meal.isHomeCooked { return "frying.pan" }
        return meal.isOrderingIn ? "bag" : "fork.knife"
    }
    private var iconColor: Color {
        if meal.isHomeCooked { return .brandForest }
        return meal.isOrderingIn ? .brandHoney : .brandTerracotta
    }

    /// A group-shared meal only ever carries a bare `recipeID` string (a
    /// backend id, resolved by `GroupPlanDestinationView` on tap, not a
    /// full local `Recipe` with photo data) — but if this same recipe also
    /// happens to exist locally (`Recipe.backendRecipeID == meal.recipeID`,
    /// true whenever it's been saved/synced on this device), that local
    /// copy's own photo is a real thumbnail worth showing rather than
    /// nothing. Falls back to the existing icon+color placeholder
    /// (`iconName`/`iconColor` above) when no local match exists — for an
    /// eat-out/order-in plan (no `recipeID` at all) or simply a recipe this
    /// device hasn't independently saved.
    private var resolvedRecipe: Recipe? {
        guard let recipeID = meal.recipeID else { return nil }
        return allRecipes.first { $0.backendRecipeID == recipeID }
    }

    var body: some View {
        // The whole row, not just the tile itself, is the tappable area
        // here — unlike `GroupSuggestionRow` below, nothing in this row's
        // visible content is its own `Button` (the only action, "Remove,"
        // lives behind `.swipeActions`, which never conflicts with a plain
        // tap), so there's no nested-button-swallows-the-tap concern to
        // work around.
        GroupPlanLinkableRow(
            recipeID: meal.recipeID, cachedRecipeTitle: meal.cachedRecipeTitle, restaurantName: meal.restaurantName,
            pushedTarget: $pushedTarget
        ) {
            // `MediaTileRow` — direct user request for one consistent tile
            // format across the Plan/Restaurants/Recipes tabs (see that
            // type's own doc comment). No accessory badge here (nothing to
            // "add" once a meal's already decided) — swipe-to-remove below
            // is this row's only action, same as before. `height: 72`
            // (shorter than the shared `mediaTileHeight` default) — direct
            // user request: this row only ever shows a title and one meta
            // line ("by so-and-so"), no actions, so it doesn't need the
            // extra height Restaurants/Recipes' fuller tiles do.
            MediaTileRow(
                title: meal.displayTitle,
                metaItems: [[(icon: "person.fill", text: "by \(memberName)")]],
                height: 72,
                thumbnail: {
                    if let resolvedRecipe {
                        RecipeThumbnail(recipe: resolvedRecipe)
                    } else {
                        ZStack {
                            iconColor.opacity(0.15)
                            Image(systemName: iconName).foregroundStyle(iconColor)
                        }
                    }
                }
            )
        }
        .swipeActions(edge: .trailing) {
            // MANAGER only — mirrors `DELETE /groups/:groupId/meal-plan/:id`
            // exactly (see routes/groupMealPlan.js).
            if isManager {
                // `role: .destructive` alone doesn't render red on a
                // `.swipeActions` button — see `PlannedMealRow`'s
                // identical fix in DayDetailView.swift for the full
                // explanation.
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }
}

/// The sheet a slot's "View Votes" button opens — direct user request: "have
/// an icon show up (only if there are suggestions) that says 'View Votes'
/// and you can look to see for each meal, who voted thumbs up and who voted
/// thumbs down." One section per suggestion in the slot, each with its own
/// explicitly-labeled thumbs-up and thumbs-down rows (`voteRow(direction:suggestion:)`
/// below) — reads `suggestion.voters` directly (see that field's own doc
/// comment on `GroupMealSuggestion`). Replaces an earlier long-press context
/// menu on each vote capsule, removed after direct user feedback that it
/// was both hard to discover and, once found, didn't visually distinguish
/// which direction's voters it was showing.
private struct SlotVotesSheet: View {
    let slotName: String
    let suggestions: [GroupMealSuggestion]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if suggestions.isEmpty {
                    Text("No suggestions for this meal yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestions) { suggestion in
                        Section(suggestion.displayTitle) {
                            voteRow(direction: .up, suggestion: suggestion)
                            voteRow(direction: .down, suggestion: suggestion)
                        }
                    }
                }
            }
            .navigationTitle("\(slotName) Votes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func voteRow(direction: VoteDirection, suggestion: GroupMealSuggestion) -> some View {
        let names = suggestion.voters.filter { $0.direction == direction }.map(\.displayName)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: direction == .up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .foregroundStyle(direction == .up ? Color.brandForest : Color.brandTerracotta)
                .frame(width: 20)
            if names.isEmpty {
                Text("No votes").foregroundStyle(.secondary)
            } else {
                Text(names.joined(separator: ", "))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GroupSuggestionRow: View {
    let suggestion: GroupMealSuggestion
    let proposerName: String
    let isManager: Bool
    let canRemove: Bool
    let isKnownOffline: Bool
    @Binding var pushedTarget: GroupPlanNavigationTarget?
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
            // Wrapped in `GroupPlanLinkableRow` — unlike `GroupPlannedMealRow`,
            // this row has real `Button`s further along (vote/"Use This"), so
            // only this leading icon+title cluster gets the tap-to-navigate
            // treatment, not the whole `HStack` — see that type's own doc
            // comment for why the whole row can't just be one `NavigationLink`
            // here the way it can there.
            GroupPlanLinkableRow(
                recipeID: suggestion.recipeID, cachedRecipeTitle: suggestion.cachedRecipeTitle,
                restaurantName: suggestion.restaurantName, pushedTarget: $pushedTarget
            ) {
                HStack {
                    Image(systemName: iconName).foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.displayTitle).font(.brandSubheadline)
                        Text("Suggested by \(proposerName)")
                            .font(.brandCaption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
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
                // `role: .destructive` alone doesn't render red on a
                // `.swipeActions` button — see `PlannedMealRow`'s
                // identical fix in DayDetailView.swift for the full
                // explanation.
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    /// The vote buttons' shared visual — an icon + count in a small
    /// capsule, filled/tinted when this is the caller's own vote and
    /// outlined/secondary otherwise. Purely presentational (this is
    /// `Button`'s `label:`, never tappable on its own).
    ///
    /// A hand-built `HStack(spacing: 2)`, not `Label(_:systemImage:)` (what
    /// this used before) — `Label`'s own icon-to-text spacing is a larger,
    /// fixed value this initializer gives no way to tighten, which is
    /// exactly what a direct user report called out: sitting next to "Use
    /// This" in the same row, that built-in gap made this pill read as
    /// stretched to roughly "Use This"'s own width even though a one-digit
    /// count needs nowhere near that much room. `spacing: 2` closes the gap
    /// between the icon and the number to what the request asked for; the
    /// capsule's height is untouched (same font, same vertical padding) —
    /// only the width shrinks, to fit the now-tighter content.
    private func voteCapsule(count: Int, systemImage: String, tint: Color, isActive: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text("\(count)")
        }
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

// MARK: - Add / suggest a meal (sheet)

/// One row of `GroupRecipePickerContent`'s "My Recipes" list — just enough
/// to render and to submit a pick for the group plan (a recipe already has
/// a real backend id the moment it's visible here, whether owned or
/// shared, so there's no id-availability problem the way a fresh
/// "Recommend a Meal" draft has). `isMine` is what
/// `GroupAddMealSheet.handleRecipePick` uses to decide whether "Add to your
/// Recipes too?" applies at all — asking to save an already-owned recipe
/// would be pointless.
private struct GroupRecipeChoice: Identifiable {
    let id: String
    let title: String
    let isMine: Bool
}

/// Identifies which sheet is presented, and with what context — the
/// group-scoped counterpart of the personal `SheetAction`. Deliberately has
/// no `setOrderReminder`/`logMeal` cases: order reminders
/// (`NotificationScheduler`) and meal-history logging (`MealHistoryEntry`)
/// are both purely local/personal-device features with no group-scoped
/// backend counterpart at all, so they're out of scope here — see this
/// feature's own final report.
///
/// A single `pickMeal(MealSlot)` case now, not four separate
/// addRecipe/addRestaurant/suggestRecipe/suggestRestaurant ones — direct
/// user feedback that six separate per-slot buttons (three MANAGER-only
/// "decide" boxes plus three "suggest instead" ones) was too much. The
/// slot/cook-dine-order/add-suggest choice those four cases used to encode
/// up front, one button each, is now made inside `GroupAddMealSheet` itself
/// via its three wheel pickers — this case just remembers which slot's "Add
/// a Meal" button was tapped, to preselect that sheet's first wheel.
enum GroupSheetAction: Identifiable {
    case pickMeal(MealSlot)

    var id: String {
        switch self {
        case .pickMeal(let slot): return "pickMeal-\(slot.rawValue)"
        }
    }
}

/// Builds the actual sheet content for a `GroupSheetAction` — currently
/// always `GroupAddMealSheet`, the combined slot/cook-dine-order/add-suggest
/// picker; see that type's own doc comment for the data-mutation logic this
/// used to hold directly (now inside that sheet, since it's the one place
/// that actually has all three wheels' final selections). Kept as its own
/// thin `View`, not folded away entirely, purely so each call site's
/// `.sheet(item:)` stays a one-line `{ action in GroupMealSheetContent(...) }`
/// — the same shape as the personal `MealSheetContent` — even though there's
/// only one case to switch on today; a second sheet-presented action here
/// again later (this file used to have five) slots back in without
/// reshaping every call site.
struct GroupMealSheetContent: View {
    let action: GroupSheetAction
    let groupID: String
    let date: Date
    let currentUserID: String?
    let isManager: Bool
    /// The group's own set default location, threaded down to
    /// `GroupAddMealSheet`'s "Ask for a Restaurant" — see
    /// `NaturalLanguageRestaurantSearchView.groupDefaultLocationText`'s own
    /// doc comment.
    var groupDefaultLocationText: String? = nil

    var body: some View {
        switch action {
        case .pickMeal(let slot):
            GroupAddMealSheet(
                groupID: groupID, date: date, initialSlot: slot, isManager: isManager, currentUserID: currentUserID,
                groupDefaultLocationText: groupDefaultLocationText
            )
        }
    }
}

/// The combined "Add a Meal" sheet a slot's single "+" button now opens —
/// direct user request for three side-by-side scrolling wheels "similar to
/// the timer on the iPhone": which slot (breakfast/lunch/dinner/other),
/// which kind (cook/dine out/order in), and which action (add/suggest).
/// Selections carry a sensible default (`initialSlot` — whichever slot's own
/// "+" was tapped — and `.add` for a MANAGER, `.suggest` for anyone else,
/// since a PARTICIPANT has no other option) but are all still freely
/// changeable, matching the request that this be one general-purpose sheet
/// rather than one preset per button.
///
/// The bottom half swaps between a recipe list (`GroupRecipePickerContent`)
/// and a restaurant search (`GroupRestaurantPickerContent`, reused for both
/// "Dine Out" and "Order In" — the middle wheel's own selection already
/// tells `submitRestaurant` below which `isOrderIn` value to insert with, so
/// that content view itself doesn't need to know or care which of the two
/// it's currently being used for) as the middle wheel
/// changes — "depending on what you select re cook, dine out, order in, the
/// bottom will either show recipes or restaurants + have a search bar," per
/// the request. Tapping a result there both submits it (`submitRecipe`/
/// `submitRestaurant` below, which read the current slot/action wheels and
/// perform the exact same local-first insert `GroupMealSheetContent`'s old
/// `decide`/`suggest` helpers used to) and dismisses the whole sheet — same
/// local-first-insert-and-dismiss-immediately pattern as every other write
/// in this feature (the real `POST` happens on the next sync; see
/// `GroupSyncService.push`).
private struct GroupAddMealSheet: View {
    let groupID: String
    let date: Date
    let isManager: Bool
    let currentUserID: String?
    let groupDefaultLocationText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedSlot: MealSlot
    @State private var selectedKind: MealKindChoice = .cook
    @State private var selectedAction: MealActionChoice

    // Owned HERE, not inside `GroupRecipePickerContent`/`GroupRestaurantPickerContent`
    // themselves — those two used to each carry this state as their own
    // `@State`/`@StateObject`, which meant flipping the middle wheel
    // between Cook/Dine Out/Order In tore down and rebuilt whichever
    // content view's `switch` branch was no longer selected (a `switch`
    // case is a distinct branch position in the composed view tree — moving
    // away from one discards its subtree's state even between the two
    // branches that both build the very same `GroupRestaurantPickerContent`
    // type). In practice: a typed search, its results, and the recipe
    // list's own network fetch all silently reset on every wheel nudge,
    // including an unintended one while scrolling an adjacent wheel.
    // Hoisting this up here and passing it down as read/write parameters
    // instead keeps it alive across every flip, for the life of the sheet.
    @State private var recipes: [GroupRecipeChoice] = []
    /// The full `SharedRecipeEntry` behind each non-owned `recipes` row,
    /// keyed by recipe id — `recipes` itself only carries id/title/`isMine`
    /// (all `GroupRecipePickerContent`'s list actually needs to render and
    /// to submit a pick for the group plan), but "Add to your Recipes too?"
    /// needs the real ingredients/instructions/photo to build a proper
    /// saved copy — see `saveToLibrary(_:)`.
    @State private var sharedRecipeEntries: [String: SharedRecipeEntry] = [:]
    @State private var isLoadingRecipes = false
    @State private var recipesErrorMessage: String?
    @State private var recipeSearchText = ""
    @State private var restaurantSearchText = ""
    @StateObject private var restaurantSearchModel = RestaurantSearchModel()
    @StateObject private var locationProvider = UserLocationProvider()

    @State private var showRecommendMeal = false
    @State private var showAskRestaurant = false
    /// Set right after a pick that ISN'T already in the caller's own
    /// personal library, to drive the "Add to your Recipes/Restaurants
    /// too?" confirmation — direct user request. `nil` for a pick that's
    /// already theirs (an owned recipe from "My Recipes," or a restaurant
    /// from "Your Restaurants") — asking to save something already saved
    /// would be pointless. The meal itself is always already planned/
    /// suggested for the group by the time this is set (see `handle*Pick`
    /// below); this only decides what happens next — sheet dismissal is
    /// deferred until the prompt resolves, see the `.confirmationDialog`
    /// this drives, below.
    @State private var pendingLibrarySave: LibrarySavePrompt?
    /// Surfaces the one online-only step in this sheet — pushing a fresh
    /// "Recommend a Meal" draft to the backend so it has a real id to plan
    /// with (see `handleRecipeDraftPick`) — failing, rather than a silent
    /// no-op.
    @State private var draftSyncErrorMessage: String?
    @State private var isSubmittingDraft = false

    init(
        groupID: String, date: Date, initialSlot: MealSlot, isManager: Bool, currentUserID: String?,
        groupDefaultLocationText: String?
    ) {
        self.groupID = groupID
        self.date = date
        self.isManager = isManager
        self.currentUserID = currentUserID
        self.groupDefaultLocationText = groupDefaultLocationText
        _selectedSlot = State(initialValue: initialSlot)
        _selectedAction = State(initialValue: isManager ? .add : .suggest)
    }

    private var normalizedDate: Date { GroupPlannedMeal.normalize(date) }

    private enum MealKindChoice: String, CaseIterable, Identifiable {
        case cook = "Cook"
        case dineOut = "Dine Out"
        case orderIn = "Order In"
        var id: String { rawValue }
    }

    private enum MealActionChoice: String, CaseIterable, Identifiable {
        case add = "Add"
        case suggest = "Suggest"
        var id: String { rawValue }
    }

    /// A PARTICIPANT only ever sees "Suggest" in the third wheel — same role
    /// gate `slotSection`'s old MANAGER-only "decide now" buttons enforced,
    /// just expressed as a filtered wheel instead of a hidden button row.
    /// Still a real (if single-row) wheel rather than hiding the whole
    /// column, so "there are 3 scrolls side by side" holds for every viewer,
    /// not just a MANAGER.
    private var actionChoices: [MealActionChoice] {
        isManager ? MealActionChoice.allCases : [.suggest]
    }

    /// Drives the "Add to your Recipes/Restaurants too?" confirmation —
    /// direct user request. Each case carries just what `saveToLibrary(_:)`
    /// needs to build the actual saved copy; see `pendingLibrarySave`'s own
    /// doc comment for when this gets set at all.
    private enum LibrarySavePrompt: Identifiable {
        case sharedRecipe(id: String, title: String)
        /// A pick from either this sheet's own inline restaurant search or
        /// "Ask for a Restaurant" — both now go through the same
        /// `RestaurantSearchModel`/`Result` the personal Restaurants tab
        /// uses (cuisine/price/rating/photos included), saved via that
        /// type's own `makeRestaurant()`, so a restaurant saved from here
        /// ends up exactly as complete as one saved from the Restaurants
        /// tab. Direct user report: saving from here used to produce a
        /// bare name-and-address `Restaurant` with none of that — a
        /// leftover from when this sheet's search used its own separate,
        /// deliberately minimal result type instead of this one.
        case richRestaurant(RestaurantSearchModel.Result)

        var id: String {
            switch self {
            case .sharedRecipe(let id, _): return "recipe-\(id)"
            case .richRestaurant(let result): return "restaurant-\(result.id)"
            }
        }

        var promptText: String {
            switch self {
            case .sharedRecipe(_, let title): return "Add \"\(title)\" to your own Recipes too?"
            case .richRestaurant(let result): return "Add \"\(result.name)\" to your own Restaurants too?"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Each `Picker` gets an explicit `.frame(maxWidth: .infinity)`
                // — without it, a `UIPickerView`-backed wheel embedded this
                // way sizes itself off its own row content ("Dine Out" is a
                // lot wider than "Lunch"), which could visibly unbalance
                // the three "equal side-by-side wheels, like the iOS timer"
                // columns the request asked for. The explicit frame forces
                // all three to split the `HStack`'s width evenly regardless
                // of how long any one column's longest row happens to be.
                // `.font(.brandCallout)` on each row's `Text` — direct user
                // feedback that the wheels' default system font size read
                // too large; a `Picker`'s row font comes from whatever's
                // inside it, not from a font set on the `Picker` itself.
                HStack(spacing: 0) {
                    Picker("Meal", selection: $selectedSlot) {
                        ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                            Text(slot.displayName).font(.brandCallout).tag(slot)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Picker("Type", selection: $selectedKind) {
                        ForEach(MealKindChoice.allCases) { kind in
                            Text(kind.rawValue).font(.brandCallout).tag(kind)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Picker("Action", selection: $selectedAction) {
                        ForEach(actionChoices) { action in
                            Text(action.rawValue).font(.brandCallout).tag(action)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .pickerStyle(.wheel)
                .frame(height: 150)
                // Nothing in this sheet's bottom half depends on `.labelsHidden()`ing
                // these — each `Picker`'s own `"Meal"`/`"Type"`/`"Action"` label
                // is never shown by `.wheel` style in the first place (unlike
                // `.menu`); left off deliberately so VoiceOver still reads a
                // name for each wheel.

                Divider()

                // Each branch gets its own "My Recipes"/"My Restaurants"
                // header above the actual picker content — direct user
                // request, so it's clear at a glance whose list this is
                // (never the group's; every group member's own personal
                // library) regardless of which of the three kinds is
                // currently selected.
                switch selectedKind {
                case .cook:
                    VStack(alignment: .leading, spacing: 0) {
                        contentHeader("My Recipes")
                        GroupRecipePickerContent(
                            recipes: recipes, isLoading: isLoadingRecipes, errorMessage: recipesErrorMessage,
                            searchText: $recipeSearchText,
                            onRetry: { Task { await loadRecipes() } },
                            onRecommend: { showRecommendMeal = true },
                            onPick: { id, title, isMine in handleRecipePick(id: id, title: title, isMine: isMine) }
                        )
                    }
                case .dineOut:
                    VStack(alignment: .leading, spacing: 0) {
                        contentHeader("My Restaurants")
                        GroupRestaurantPickerContent(
                            searchText: $restaurantSearchText, searchModel: restaurantSearchModel, locationProvider: locationProvider,
                            onAskForRestaurant: { showAskRestaurant = true },
                            onSubmit: { name, richResult in handleRestaurantPick(name: name, isOrderIn: false, richResult: richResult) }
                        )
                    }
                case .orderIn:
                    VStack(alignment: .leading, spacing: 0) {
                        contentHeader("My Restaurants")
                        GroupRestaurantPickerContent(
                            searchText: $restaurantSearchText, searchModel: restaurantSearchModel, locationProvider: locationProvider,
                            onAskForRestaurant: { showAskRestaurant = true },
                            onSubmit: { name, richResult in handleRestaurantPick(name: name, isOrderIn: true, richResult: richResult) }
                        )
                    }
                }
            }
            .overlay {
                // Only ever shown for the one genuinely online-dependent
                // step in this sheet — see `handleRecipeDraftPick`'s own
                // doc comment for why a fresh "Recommend a Meal" draft
                // needs a real network round trip before it can be
                // planned/suggested for the group at all.
                if isSubmittingDraft {
                    Color.black.opacity(0.05).ignoresSafeArea()
                    ProgressView("Saving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Add a Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadRecipes() }
            // Symmetric on purpose, not just the demotion half — `isManager`
            // isn't frozen at presentation time (`GroupMealSheetContent`'s
            // `.sheet(item:)` closure re-evaluates this sheet's `isManager`
            // parameter whenever the presenting screen's body recomputes
            // while this sheet stays open), and `loadGroup()` on the
            // presenting screen resolves asynchronously — a MANAGER who taps
            // "Add a Meal" in the brief window before that finishes gets
            // `isManager: false` at `init`, defaulting `selectedAction` to
            // `.suggest`; without the promotion half here too, it would stay
            // stuck there even once `isManager` catches up to `true`, silently
            // defaulting a manager's own sheet to "Suggest" instead of "Add".
            .onChange(of: isManager) { _, stillManager in
                selectedAction = stillManager ? .add : .suggest
            }
            .sheet(isPresented: $showRecommendMeal) {
                RecommendMealView(onPick: { draft in Task { await handleRecipeDraftPick(draft) } })
            }
            .sheet(isPresented: $showAskRestaurant) {
                NaturalLanguageRestaurantSearchView(
                    userCoordinate: locationProvider.coordinate,
                    groupDefaultLocationText: groupDefaultLocationText,
                    onPick: { result in
                        handleRestaurantPick(name: result.name, isOrderIn: selectedKind == .orderIn, richResult: result)
                    }
                )
            }
            // The meal itself is already planned/suggested for the group by
            // the time this appears (see each `handle*Pick` above/below) —
            // this only decides whether a copy also gets saved to the
            // picker's own personal library, and either answer dismisses
            // the whole sheet once resolved (see `pendingLibrarySave`'s own
            // doc comment for why dismissal waits for this rather than
            // happening immediately on pick).
            .confirmationDialog(
                pendingLibrarySave?.promptText ?? "",
                isPresented: Binding(get: { pendingLibrarySave != nil }, set: { if !$0 { pendingLibrarySave = nil } }),
                titleVisibility: .visible
            ) {
                Button("Add It") {
                    if let pendingLibrarySave { saveToLibrary(pendingLibrarySave) }
                    pendingLibrarySave = nil
                    dismiss()
                }
                Button("Not Now", role: .cancel) {
                    pendingLibrarySave = nil
                    dismiss()
                }
            }
            .alert(
                "Couldn't Add to the Group's Plan",
                isPresented: Binding(get: { draftSyncErrorMessage != nil }, set: { if !$0 { draftSyncErrorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(draftSyncErrorMessage ?? "")
            }
        }
    }

    /// A small bold label above whichever of `GroupRecipePickerContent`/
    /// `GroupRestaurantPickerContent` is currently showing — see the
    /// `switch` above for why.
    private func contentHeader(_ title: String) -> some View {
        Text(title)
            .font(.brandCaption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
    }

    private func loadRecipes() async {
        isLoadingRecipes = true
        recipesErrorMessage = nil
        defer { isLoadingRecipes = false }
        do {
            async let mine = AccountsAPIClient.getMyRecipes()
            async let shared = AccountsAPIClient.getSharedRecipes()
            let (mineResult, sharedResult) = try await (mine, shared)
            let mineIDs = Set(mineResult.map(\.id))
            var byID: [String: GroupRecipeChoice] = [:]
            for recipe in mineResult {
                byID[recipe.id] = GroupRecipeChoice(id: recipe.id, title: recipe.title, isMine: true)
            }
            // `where !mineIDs.contains` — a recipe shared with the caller
            // that they also already own (however that happened) stays
            // `isMine: true`, not overwritten by its shared-list entry.
            for entry in sharedResult where !mineIDs.contains(entry.recipeID) {
                byID[entry.recipeID] = GroupRecipeChoice(id: entry.recipeID, title: entry.title, isMine: false)
                sharedRecipeEntries[entry.recipeID] = entry
            }
            recipes = byID.values.sorted { $0.title < $1.title }
        } catch {
            recipesErrorMessage = error.localizedDescription
        }
    }

    /// A pick from `GroupRecipePickerContent`'s own "My Recipes" list —
    /// already a real backend recipe either way (owned or shared), so this
    /// plans/suggests it for the group immediately; `isMine == false` is
    /// the one case that also offers "Add to your Recipes too?" (saving a
    /// friend's shared recipe as your own copy — see `saveToLibrary(_:)`).
    private func handleRecipePick(id: String, title: String, isMine: Bool) {
        guard insert(recipeID: id, recipeTitle: title) else { return }
        if isMine {
            dismiss()
        } else {
            pendingLibrarySave = .sharedRecipe(id: id, title: title)
        }
    }

    /// A pick from "Recommend a Meal" — unlike every other pick this sheet
    /// handles, an AI-drafted recipe has no backend id at all yet, and
    /// `GroupPlannedMeal`/`GroupMealSuggestion.recipeID` can only ever
    /// reference a real one (there's no "just a title, no real recipe"
    /// path for a *recipe* suggestion the way `restaurantName` is a free
    /// string for a restaurant one — see `GroupPlannedMeal.recipeID`'s own
    /// doc comment). So saving this to My Recipes isn't an optional
    /// afterthought the way it is for every other pick here — it's the
    /// only way to get the real id planning it for the group needs, which
    /// is why there's no `pendingLibrarySave` confirmation for this path:
    /// the draft is inserted and pushed to the backend immediately, and
    /// only once that succeeds does it get submitted to the group plan.
    /// `isSubmittingDraft` drives the loading overlay for this one
    /// genuinely network-dependent step.
    private func handleRecipeDraftPick(_ draft: RecipeDraft) async {
        let recipe = draft.makeRecipe(createdByMemberID: nil)
        modelContext.insert(recipe)
        try? modelContext.save()
        isSubmittingDraft = true
        defer { isSubmittingDraft = false }
        do {
            let created = try await AccountsAPIClient.createRecipe(RecipeLibraryPayload(recipe: recipe))
            recipe.backendRecipeID = created.id
            guard insert(recipeID: created.id, recipeTitle: recipe.title) else { return }
            dismiss()
        } catch {
            // The recipe is still saved locally (visible in My Recipes
            // right away) regardless of this failure — only the "plan it
            // for the group" half didn't happen. The next opportunistic
            // `PersonalLibrarySyncService` pass (the Recipes tab's own
            // `.task`, or this account's next sign-in) will still push it
            // and give it a real id then; the group plan just doesn't have
            // it yet.
            draftSyncErrorMessage = "Saved \"\(recipe.title)\" to your Recipes, but couldn't reach the server to add it to the group's plan — try again once you're back online."
        }
    }

    /// A pick from `GroupRestaurantPickerContent`'s own inline search or
    /// from "Ask for a Restaurant" (`richResult` non-`nil` for either —
    /// live search data not yet saved, never for a pick from "Your
    /// Restaurants" — see that view's own `onSubmit`). `restaurantName`
    /// needs no backend id at all (a free string — see
    /// `GroupPlannedMeal.restaurantName`'s own doc comment), so this always
    /// plans/suggests it for the group immediately, same as a recipe pick;
    /// `richResult != nil` is what decides whether "Add to your Restaurants
    /// too?" also applies — and, now that it carries the same
    /// `RestaurantSearchModel.Result` the Restaurants tab itself searches
    /// with, that save gets the full cuisine/price/rating/photos, not just
    /// a bare name and address.
    private func handleRestaurantPick(name: String, isOrderIn: Bool, richResult: RestaurantSearchModel.Result?) {
        guard insert(restaurantName: name, isOrderIn: isOrderIn) else { return }
        if let richResult {
            pendingLibrarySave = .richRestaurant(richResult)
        } else {
            dismiss()
        }
    }

    /// Builds and inserts the actual saved copy `pendingLibrarySave`
    /// describes — called only from the "Add It" branch of this sheet's
    /// own `.confirmationDialog`.
    private func saveToLibrary(_ prompt: LibrarySavePrompt) {
        switch prompt {
        case .sharedRecipe(let id, _):
            if let entry = sharedRecipeEntries[id] {
                modelContext.insert(entry.makeLocalRecipe())
            }
        case .richRestaurant(let result):
            modelContext.insert(result.makeRestaurant())
        }
    }

    @discardableResult
    private func insert(
        recipeID: String? = nil, recipeTitle: String? = nil,
        restaurantName: String? = nil, isOrderIn: Bool = false
    ) -> Bool {
        guard let currentUserID else { return false }
        switch selectedAction {
        case .add:
            let meal = GroupPlannedMeal(
                id: GroupPlannedMeal.newLocalPlaceholderID(), groupID: groupID, date: normalizedDate, slot: selectedSlot,
                recipeID: recipeID, cachedRecipeTitle: recipeTitle, restaurantName: restaurantName,
                isOrderIn: isOrderIn, decidedByUserID: currentUserID, syncState: .pendingCreate
            )
            modelContext.insert(meal)
        case .suggest:
            let suggestion = GroupMealSuggestion(
                id: GroupMealSuggestion.newLocalPlaceholderID(), groupID: groupID, date: normalizedDate, slot: selectedSlot,
                recipeID: recipeID, cachedRecipeTitle: recipeTitle, restaurantName: restaurantName, isOrderIn: isOrderIn,
                proposedByUserID: currentUserID, myVote: .up, upvoteCount: 1, downvoteCount: 0, syncState: .pendingCreate
            )
            modelContext.insert(suggestion)
        }
        try? modelContext.save()
        return true
    }
}

/// A real restaurant *search* — not a bare free-text field — for the group
/// meal plan's "decide"/"suggest" restaurant flow. This used to be a plain
/// `TextField("Restaurant name", text: $name)`: nothing stopped someone from
/// typing gibberish and having it "suggest" a place that doesn't exist,
/// since the field had no connection to any real-world data at all (see
/// this feature's user-reported bug report). Fixed two ways:
///
/// 1. **Live search-as-you-type**, tapping a real result to pick it — the
///    same `RestaurantSearchModel` (**Google Places first, `MKLocalSearch`
///    fallback**) the personal Restaurants tab itself searches with,
///    reused directly rather than duplicated. An earlier version of this
///    view kept its own separate, deliberately minimal `GroupRestaurantSearchModel`
///    (id/name/address only) instead, reasoning that this screen has no use
///    for `RestaurantSearchModel.Result`'s rating/price/cuisine/photos since
///    `restaurantName` here is, and stays, a plain string either way — true
///    for what gets planned, but it also meant "Add to your Restaurants
///    too?" (below) could only ever save a bare name-and-address
///    `Restaurant`, missing everything a restaurant saved from the
///    Restaurants tab itself gets (direct user report). Reusing the real
///    model outright fixes that at no extra cost — `RestaurantSearchModel`
///    has no dependency this screen doesn't already have.
/// 2. **A "Your Restaurants" quick-pick**, listing this device's own saved,
///    personal `Restaurant` rows (the same ones `RestaurantListView` shows
///    under "Restaurants") above the live search — user feedback was that
///    "eat out and order in has a search bar and not the options you have
///    from your restaurant list." Tapping one submits its name exactly like
///    a live search result does; nothing here reads or writes the `Restaurant`
///    row itself, so no group-scoped schema is involved. Nothing here to
///    "save" either — it's already in the user's own library — so `onSubmit`
///    passes `nil` for the second (rich-result) parameter in this path.
///
/// **What gets planned**: a result's/saved restaurant's plain name alone,
/// not "name, address" — every downstream display of `restaurantName`
/// (`GroupPlannedMealRow`'s tile title, `GroupSuggestionRow`, `GroupAgendaDayRow`'s
/// one-line slot summary) is a compact, space-constrained label, the same
/// shape a hand-typed name always produced, and an address tacked on would
/// either get silently truncated there or badly overflow a title sized for a
/// short name. The result list still shows the address as a secondary line
/// — enough to tell two same-named places apart before picking one — it
/// just isn't carried into the string that ends up planned for the group.
/// The full result (address included) still reaches `GroupAddMealSheet` as
/// the second `onSubmit` parameter, purely for the "Add to your Restaurants
/// too?" save.
///
/// Embedded directly in `GroupAddMealSheet`'s bottom half — no
/// `NavigationStack`/toolbar/title of its own (this used to be a standalone
/// sheet, `GroupRestaurantNameSheet`, presented directly from a slot's own
/// "Eat Out"/"Order In" button; now `GroupAddMealSheet` supplies all of
/// that chrome once for whichever content — this or `GroupRecipePickerContent`
/// — the middle wheel currently selects). A plain `TextField`, not
/// `.searchable`, for the same reason: `.searchable`'s navigation-bar
/// placement assumes it's attached to a `NavigationStack`'s direct content,
/// not to one branch of a `switch` nested a couple of levels down inside
/// one — unreliable exactly where this view now lives. `onSubmit` alone,
/// with no `dismiss()` of its own — the caller (`GroupAddMealSheet`) is the
/// one that knows which of "add" or "suggest" this selection means and
/// performs the actual insert, then dismisses the whole sheet itself.
private struct GroupRestaurantPickerContent: View {
    // `searchText`/`searchModel`/`locationProvider` are all owned by
    // `GroupAddMealSheet`, not this view — see that type's own doc comment
    // on its matching `@State`/`@StateObject` properties for why: this
    // content view is torn down and rebuilt every time the middle wheel
    // flips between Dine Out and Order In (both build this exact same type,
    // but from different `switch` case branches, which don't share state),
    // so anything genuinely owned here would reset — an in-progress search
    // and its results included — on every flip. Passed down instead, they
    // survive the flip untouched.
    @Binding var searchText: String
    @ObservedObject var searchModel: RestaurantSearchModel
    @ObservedObject var locationProvider: UserLocationProvider
    /// Opens "Ask for a Restaurant" (`NaturalLanguageRestaurantSearchView`)
    /// — direct user request to offer that alongside the plain search bar,
    /// not just from the personal Restaurants tab.
    let onAskForRestaurant: () -> Void
    /// The second parameter is `nil` for a "Your Restaurants" pick (already
    /// saved — nothing to offer adding), the full search result for a live
    /// search pick (not yet saved) — `GroupAddMealSheet.handleRestaurantPick`
    /// uses it both to decide whether "Add to your Restaurants too?" applies
    /// and, if so, to save a fully-detailed copy via that result's own
    /// `makeRestaurant()`.
    let onSubmit: (String, RestaurantSearchModel.Result?) -> Void

    /// This device's own saved, personal restaurants — see this type's own
    /// doc comment for why they're offered here too, not just live search
    /// results. Unfiltered by `searchText` on purpose: `RestaurantListView`
    /// itself always shows the full "Your Restaurants" list regardless of
    /// whether a search is active, and this view matches that precedent
    /// exactly rather than inventing a different rule.
    @Query(sort: \Restaurant.name) private var savedRestaurants: [Restaurant]

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List {
                if isSearchActive {
                    searchResultsSection
                }
                if savedRestaurants.isEmpty && !isSearchActive {
                    Text("Search above to find a place, or save some to Restaurants to see them here.")
                        .foregroundStyle(.secondary)
                } else if !savedRestaurants.isEmpty {
                    savedRestaurantsSection
                }
            }
            .listStyle(.plain)
        }
        .onAppear {
            locationProvider.requestIfNeeded()
        }
        .onChange(of: locationProvider.coordinate) { _, newValue in
            searchModel.userCoordinate = newValue
        }
    }

    /// The "Ask for a Restaurant" (sparkles) button lives right in this
    /// same row, next to the plain search field — direct user request
    /// ("can we also add the functionality around ... ask for a
    /// restaurant (next to the search bar)").
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for a restaurant", text: $searchText)
                .onChange(of: searchText) { _, newValue in searchModel.search(newValue) }
            Button(action: onAskForRestaurant) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(!GooglePlacesService.isConfigured || !ClaudeRecipeService.isConfigured)
            .accessibilityLabel("Ask for a Restaurant")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 12)
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
                        onSubmit(result.name, result)
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
                    onSubmit(restaurant.name, nil)
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
///
/// Embedded directly in `GroupAddMealSheet`'s bottom half — same "no
/// `NavigationStack`/toolbar/title of its own, plain `TextField` instead of
/// `.searchable`, `onPick` alone with no internal `dismiss()`" reasoning as
/// `GroupRestaurantPickerContent`'s own doc comment (this used to be a
/// standalone sheet, `GroupRecipePickerSheet`, the same way that one was).
///
/// `recipes`/`isLoading`/`errorMessage` are passed in rather than owned
/// here (this view used to load and hold them itself) — same reasoning as
/// `GroupRestaurantPickerContent`'s own `searchText`/`searchModel`/
/// `locationProvider`: `GroupAddMealSheet` swaps this view in and out of a
/// `switch` on its middle wheel, which tears down and rebuilds whatever
/// state a view here would otherwise own on every flip away from and back
/// to "Cook" — including re-firing the network fetch this data comes from.
/// `searchText` stays local `@State` here, unlike those three, since
/// nothing else needs to read or reset it from outside.
private struct GroupRecipePickerContent: View {
    let recipes: [GroupRecipeChoice]
    let isLoading: Bool
    let errorMessage: String?
    @Binding var searchText: String
    let onRetry: () -> Void
    /// Opens "Recommend a Meal" (`RecommendMealView`) — direct user request
    /// to offer that alongside the plain search bar, not just from the
    /// personal Recipes tab.
    let onRecommend: () -> Void
    /// `isMine` lets `GroupAddMealSheet.handleRecipePick` decide whether
    /// "Add to your Recipes too?" applies — a pick that's already the
    /// caller's own recipe has nothing left to add.
    let onPick: (String, String, Bool) -> Void

    private var filteredRecipes: [GroupRecipeChoice] {
        guard !searchText.isEmpty else { return recipes }
        return recipes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            List {
                if isLoading && recipes.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry", action: onRetry)
                } else if recipes.isEmpty {
                    ContentUnavailableView(
                        "No Recipes Yet",
                        systemImage: "book",
                        description: Text("Only recipes you own, or that have been shared with you, can be planned here. Share one from Recipes first, or tap ✨ above for an idea.")
                    )
                } else if filteredRecipes.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRecipes) { recipe in
                        Button {
                            onPick(recipe.id, recipe.title, recipe.isMine)
                        } label: {
                            Text(recipe.title).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// The "Recommend a Meal" (sparkles) button lives right in this same
    /// row, next to the plain search field — direct user request ("can we
    /// also add the functionality around recommend a meal ... next to the
    /// search bar").
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your recipes", text: $searchText)
            Button(action: onRecommend) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(!ClaudeRecipeService.isConfigured)
            .accessibilityLabel("Recommend a Meal")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 12)
    }
}
