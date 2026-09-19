import SwiftUI
import SwiftData

/// One day's plan, broken into Breakfast / Lunch / Dinner / Other, pushed as
/// its own screen (from the "Weekly" agenda, or "Plan the Week"'s "Plan
/// breakfast, lunch & more" link). The Calendar tab's own day panel wants
/// the exact same per-slot content embedded inline instead of behind a
/// push — see `DaySlotsView` below, which is where all of the actual slot
/// logic lives; this is just that plus the `Form`/navigation-title chrome a
/// standalone pushed screen needs.
struct DayDetailView: View {
    let date: Date

    // Owned here rather than inside `DaySlotsView` — see the note above
    // `DaySlotsView.activeSheet` for why, and why `.sheet(item:)` is
    // attached to this `Form` itself instead of to anything nested inside it.
    @State private var activeSheet: SheetAction?

    var body: some View {
        Form {
            DaySlotsView(date: date, activeSheet: $activeSheet)
        }
        .navigationTitle(date.formatted(Date.weekdayFull))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { action in
            MealSheetContent(action: action, date: date, activeSheet: $activeSheet)
        }
    }
}

/// The actual per-slot planning content for one day — Breakfast / Lunch /
/// Dinner / Other, each able to hold more than one decided meal (a dinner
/// plan *and* an ice-cream run afterward both live in the same day,
/// different slots — or even the same slot, if the family genuinely can't
/// decide between two options), plus its own suggestions and votes.
///
/// Pulled out of `DayDetailView` so the exact same content — and all its
/// sheet/decide/vote logic — can be embedded directly inside another
/// `List`/`Form` (the Calendar tab's own inline day panel) as well as
/// pushed as its own screen, without duplicating any of it. Renders as a
/// sequence of `Section`s — callers provide whatever `Form`/`List` wraps them.
struct DaySlotsView: View {
    let date: Date

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \PlannedMeal.decidedAt) private var allPlannedMeals: [PlannedMeal]
    @Query(sort: \MealSuggestion.createdAt) private var allSuggestions: [MealSuggestion]
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    /// Which sheet slot/meal action is pending, if any — owned by whichever
    /// screen embeds this view (`DayDetailView`'s `Form`, or
    /// `CalendarPlanView`'s `List`), not by this view itself.
    ///
    /// This used to be a plain `@State` here, with `.sheet(item:)` attached
    /// directly to this view's own `body` (below). That worked fine pushed
    /// inside `DayDetailView`'s `Form`, but flashed-then-immediately-dismissed
    /// the first time it was tapped from `CalendarPlanView`'s inline day
    /// panel — exactly the "pops up and disappears, works the second time"
    /// symptom, for a plain button this time, not a `Menu` one (that's the
    /// unrelated race `presentAfterMenuDismiss` fixes, above).
    ///
    /// The mechanism: `CalendarPlanView` embeds this view's content directly
    /// as rows inside a `List` that also carries
    /// `.animation(.default, value: selectedDate)` on the whole `List`, to
    /// animate the day panel sliding to a new day's plan. A `.sheet`
    /// modifier attached to content nested *inside* that `List`'s row
    /// content — rather than on the `List` itself — presents by asking the
    /// row's own hosting controller to present modally; but that same
    /// `List`, being backed by `UICollectionView`, can concurrently run an
    /// animated batch-update pass over its rows whenever *any* dependency
    /// tracked by the animated `List` changes state, and the two animated
    /// transactions (UIKit's modal-presentation animation and the list's row
    /// batch-update animation) race. When the list's batch update wins, the
    /// presenting row gets invalidated/re-laid-out mid-presentation and the
    /// sheet is torn back down before it finishes appearing — resetting
    /// `activeSheet` to `nil` in the process, which is why tapping the exact
    /// same button again works: that second tap has no competing batch
    /// update in flight. `DayDetailView`'s plain `Form` has no `.animation`
    /// modifier, so it never raced and never showed the bug.
    ///
    /// The fix is to stop presenting from inside the animated `List`'s row
    /// content at all: each caller now owns `activeSheet` itself and attaches
    /// `.sheet(item:)` to its own `Form`/`List` root (outside any row/section
    /// content, and outside the `.animation` modifier's subtree), passing a
    /// binding down into this view instead. This view only ever *sets* the
    /// binding; the sheet's content is built by `MealSheetContent`, below,
    /// which each caller instantiates from its own `.sheet(item:)`.
    @Binding var activeSheet: SheetAction?

    private var normalizedDate: Date { PlannedMeal.normalize(date) }

    private func meals(for slot: MealSlot) -> [PlannedMeal] {
        allPlannedMeals.filter { $0.date.isSameDay(as: normalizedDate) && $0.slot == slot }
    }

    private func suggestions(for slot: MealSlot) -> [MealSuggestion] {
        allSuggestions
            .filter { $0.date.isSameDay(as: normalizedDate) && $0.slot == slot }
            .sorted { $0.voteCount > $1.voteCount }
    }

    var body: some View {
        // No `.sheet` here anymore — see `activeSheet` above for why. Each
        // caller attaches it to its own `Form`/`List` root instead.
        ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
            slotSection(slot)
        }
    }

    @ViewBuilder
    private func slotSection(_ slot: MealSlot) -> some View {
        // With nothing decided or suggested yet, the buttons would otherwise
        // sit flush against the section header — fine once there's a meal
        // pill to separate them from it, but cramped-looking against a
        // header with nothing in between. Only that empty case gets the
        // extra breathing room back.
        let isEmpty = meals(for: slot).isEmpty && suggestions(for: slot).isEmpty

        Section {
            ForEach(meals(for: slot)) { meal in
                PlannedMealRow(
                    meal: meal,
                    member: members.first(where: { $0.id == meal.decidedByMemberID }),
                    onLog: { activeSheet = .logMeal(meal) },
                    onRemove: {
                        if meal.orderReminderDate != nil {
                            NotificationScheduler.cancelOrderReminder(for: meal)
                        }
                        modelContext.delete(meal)
                    },
                    onCancelReminder: {
                        NotificationScheduler.cancelOrderReminder(for: meal)
                        meal.orderReminderDate = nil
                    }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }
            ForEach(suggestions(for: slot)) { suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    members: members,
                    onVote: { toggleVote(on: suggestion) },
                    onAdopt: { adopt(suggestion) },
                    onRemove: { removeSuggestion(suggestion) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }

            // Three single-tap buttons instead of a two-tap "Add" menu — the
            // three things you're actually deciding between for any given
            // meal. Suggesting-for-a-vote is a less common path, so it stays
            // reachable but out of the way, as a small menu below rather
            // than a fourth equally-weighted button. Both live in one Form
            // row (a VStack), not two — Form/List rows each carry their own
            // minimum height regardless of how tight the insets are set, so
            // the only way to actually remove the gap *between* these two is
            // to stop them being separate rows in the first place.
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    SlotAddButton(title: "Add a Recipe", systemImage: "frying.pan") {
                        activeSheet = .addRecipe(slot)
                    }
                    SlotAddButton(title: "Eat Out", systemImage: "fork.knife") {
                        activeSheet = .addRestaurant(slot)
                    }
                    SlotAddButton(title: "Order In", systemImage: "bag") {
                        activeSheet = .orderIn(slot)
                    }
                }

                Menu {
                    Button { presentAfterMenuDismiss { activeSheet = .suggestRecipe(slot) } } label: {
                        Label("Suggest a Recipe", systemImage: "bubble.left")
                    }
                    Button { presentAfterMenuDismiss { activeSheet = .suggestRestaurant(slot) } } label: {
                        Label("Suggest Eating Out", systemImage: "bubble.left")
                    }
                    Button { presentAfterMenuDismiss { activeSheet = .suggestOrderIn(slot) } } label: {
                        Label("Suggest Ordering In", systemImage: "bubble.left")
                    }
                } label: {
                    Text("Suggest something instead (for a vote)")
                }
                .font(.brandCaption)
            }
            .listRowInsets(EdgeInsets(top: isEmpty ? 14 : 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        } header: {
            Label(slot.displayName, systemImage: slot.symbolName)
        }
    }

    private func toggleVote(on suggestion: MealSuggestion) {
        guard let memberID = activeUserSession.activeMemberID else { return }
        suggestion.toggleVote(for: memberID)
    }

    /// "Use This" on a suggestion — decides it the same way `MealSheetContent`
    /// decides a freshly-picked recipe/restaurant (via the same shared
    /// `decideMeal` helper), just triggered directly by this row's button
    /// rather than from inside a picker sheet's `onPick`.
    private func adopt(_ suggestion: MealSuggestion) {
        let reminder = decideMeal(
            slot: suggestion.slot,
            date: date,
            recipe: suggestion.recipe,
            restaurant: suggestion.restaurant,
            isOrderIn: suggestion.isOrderIn,
            decidedByMemberID: activeUserSession.activeMemberID,
            modelContext: modelContext
        )
        modelContext.delete(suggestion)
        if let reminder {
            Task { @MainActor in
                activeSheet = .setOrderReminder(reminder.meal, reminder.restaurant)
            }
        }
    }

    /// Withdraws a suggestion you (or anyone) proposed — for when whoever
    /// suggested it changes their mind, rather than leaving it sitting
    /// there to be voted on or adopted.
    private func removeSuggestion(_ suggestion: MealSuggestion) {
        modelContext.delete(suggestion)
    }
}

/// Creates and inserts a `PlannedMeal` for a decided slot — shared by
/// `DaySlotsView.adopt(_:)` (adopting an existing suggestion directly) and
/// `MealSheetContent`'s own picker callbacks (deciding a freshly-picked
/// recipe/restaurant), so the two paths can't drift apart. Returns the
/// meal + restaurant to offer a reminder for when this decision is an
/// order-in; the caller is responsible for actually presenting that
/// reminder sheet, deferred to the next run loop turn when called from
/// inside a picker sheet's `onPick` — that callback runs immediately
/// before that sheet's own `dismiss()`, and changing `activeSheet`
/// synchronously in the same tick would race it.
@discardableResult
private func decideMeal(
    slot: MealSlot,
    date: Date,
    recipe: Recipe? = nil,
    restaurant: Restaurant? = nil,
    isOrderIn: Bool = false,
    decidedByMemberID: UUID?,
    modelContext: ModelContext
) -> (meal: PlannedMeal, restaurant: Restaurant)? {
    let meal = PlannedMeal(
        date: PlannedMeal.normalize(date),
        slot: slot,
        recipe: recipe,
        restaurant: restaurant,
        isOrderIn: isOrderIn,
        decidedByMemberID: decidedByMemberID
    )
    modelContext.insert(meal)
    if isOrderIn, let restaurant {
        return (meal, restaurant)
    }
    return nil
}

/// Builds the actual sheet content for a `SheetAction`, and performs the
/// data mutations (creating a `PlannedMeal` or `MealSuggestion`) each picker's
/// `onPick` triggers. Pulled out of `DaySlotsView` so it can be handed
/// straight to whichever caller's own `.sheet(item:)` builds it — see the
/// note on `DaySlotsView.activeSheet` for why that modifier no longer lives
/// on `DaySlotsView` itself. Declared as its own `View` (not a free function)
/// specifically so its `@Environment`/`@Query` properties get populated the
/// normal way, by SwiftUI actually mounting it as the sheet's root content —
/// calling methods directly on a `DaySlotsView` value built outside the view
/// hierarchy wouldn't reliably see the right `modelContext` et al.
struct MealSheetContent: View {
    let action: SheetAction
    let date: Date
    @Binding var activeSheet: SheetAction?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    private var normalizedDate: Date { PlannedMeal.normalize(date) }

    var body: some View {
        switch action {
        case .addRecipe(let slot):
            RecipePickerSheet { recipe in
                decide(slot: slot, recipe: recipe)
            }
        case .addRestaurant(let slot):
            RestaurantPickerSheet { restaurant in
                decide(slot: slot, restaurant: restaurant)
            }
        case .orderIn(let slot):
            RestaurantPickerSheet { restaurant in
                decide(slot: slot, restaurant: restaurant, isOrderIn: true)
            }
        case .setOrderReminder(let meal, let restaurant):
            OrderReminderSheet(meal: meal, restaurant: restaurant)
        case .suggestRecipe(let slot):
            RecipePickerSheet { recipe in
                addSuggestion(slot: slot, recipe: recipe)
            }
        case .suggestRestaurant(let slot):
            RestaurantPickerSheet { restaurant in
                addSuggestion(slot: slot, restaurant: restaurant)
            }
        case .suggestOrderIn(let slot):
            RestaurantPickerSheet { restaurant in
                addSuggestion(slot: slot, restaurant: restaurant, isOrderIn: true)
            }
        case .logMeal(let meal):
            LogMealSheet(meal: meal)
        }
    }

    private func decide(slot: MealSlot, recipe: Recipe? = nil, restaurant: Restaurant? = nil, isOrderIn: Bool = false) {
        let reminder = decideMeal(
            slot: slot,
            date: date,
            recipe: recipe,
            restaurant: restaurant,
            isOrderIn: isOrderIn,
            decidedByMemberID: activeUserSession.activeMemberID,
            modelContext: modelContext
        )
        if let reminder {
            Task { @MainActor in
                activeSheet = .setOrderReminder(reminder.meal, reminder.restaurant)
            }
        }
    }

    private func addSuggestion(slot: MealSlot, recipe: Recipe? = nil, restaurant: Restaurant? = nil, isOrderIn: Bool = false) {
        guard let memberID = activeUserSession.activeMemberID ?? members.first?.id else { return }
        let suggestion = MealSuggestion(
            date: normalizedDate,
            slot: slot,
            proposedByMemberID: memberID,
            recipe: recipe,
            restaurant: restaurant,
            isOrderIn: isOrderIn
        )
        modelContext.insert(suggestion)
    }
}

/// Identifies which sheet is presented, and with what context, from a single
/// `@State` var rather than a pile of booleans (each day has 4 slots × 4
/// possible add/suggest actions, plus per-meal logging).
///
/// Internal (not `private`) — both `DayDetailView` and `CalendarPlanView`
/// (in a different file) own their own `@State` of this type and pass a
/// binding down into `DaySlotsView`.
enum SheetAction: Identifiable {
    case addRecipe(MealSlot)
    case addRestaurant(MealSlot)
    case orderIn(MealSlot)
    case setOrderReminder(PlannedMeal, Restaurant)
    case suggestRecipe(MealSlot)
    case suggestRestaurant(MealSlot)
    case suggestOrderIn(MealSlot)
    case logMeal(PlannedMeal)

    var id: String {
        switch self {
        case .addRecipe(let slot): return "addRecipe-\(slot.rawValue)"
        case .addRestaurant(let slot): return "addRestaurant-\(slot.rawValue)"
        case .orderIn(let slot): return "orderIn-\(slot.rawValue)"
        case .setOrderReminder(let meal, _): return "setOrderReminder-\(meal.id.uuidString)"
        case .suggestRecipe(let slot): return "suggestRecipe-\(slot.rawValue)"
        case .suggestRestaurant(let slot): return "suggestRestaurant-\(slot.rawValue)"
        case .suggestOrderIn(let slot): return "suggestOrderIn-\(slot.rawValue)"
        case .logMeal(let meal): return "logMeal-\(meal.id.uuidString)"
        }
    }
}

/// One of the three single-tap "decide now" buttons in a slot section.
/// Deliberately small and quiet — this is the "add" affordance, not the
/// content, and shouldn't visually compete with an actual planned meal
/// (`PlannedMealRow`'s icon+pill shape, below) once one exists. Explicitly
/// NOT `.buttonStyle(.bordered)`: that style draws its own background with
/// its own fixed minimum padding/height, which doesn't actually shrink just
/// because the font inside it does — `.plain` plus a hand-drawn fill is what
/// makes this genuinely smaller than the pill above, not just the text.
private struct SlotAddButton: View {
    let title: String
    let systemImage: String
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
                // "Evergreen" from the brand sheet — same swatch as
                // Color.brandForest elsewhere in the app.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brandForest)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PlannedMealRow: View {
    let meal: PlannedMeal
    let member: FamilyMember?
    let onLog: () -> Void
    let onRemove: () -> Void
    let onCancelReminder: () -> Void

    /// A distinct icon+color per kind, so the pill below reads at a glance —
    /// same three colors as the calendar's own legend/status dots.
    private var iconName: String {
        if meal.recipe != nil { return "frying.pan" }
        return meal.isOrderingIn ? "bag" : "fork.knife"
    }
    private var iconColor: Color {
        if meal.recipe != nil { return .brandForest }
        return meal.isOrderingIn ? .brandHoney : .brandTerracotta
    }

    var body: some View {
        HStack {
            // Its own pill shape — smaller icons elsewhere (the three add
            // buttons) shouldn't visually compete with an actual decided
            // meal, so this one gets a background and a bigger icon than
            // either of those use.
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                if let recipe = meal.recipe {
                    NavigationLink(recipe.title) {
                        RecipeDetailView(recipe: recipe)
                    }
                } else {
                    Text(meal.displayTitle)
                }
            }
            .font(.brandHeadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(iconColor.opacity(0.12), in: Capsule())
            if let reminderDate = meal.orderReminderDate {
                Image(systemName: "bell.fill")
                    .font(.brandCaption)
                    .foregroundStyle(.secondary)
                    .help("Reminder at \(reminderDate.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            if let member {
                MemberBadgeView(member: member, size: 20)
            }
        }
        .swipeActions(edge: .trailing) {
            // `role: .destructive` alone doesn't actually render red here —
            // direct user report that it was showing the app's own global
            // accent (olive) instead. A `.swipeActions` button always
            // needs an explicit `.tint` (it doesn't fall back to a
            // system-standard destructive red the way, say, a `Button`
            // inside a `.alert` does); every destructive swipe action in
            // the app gets this same explicit `.tint(.red)` now.
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
            if meal.date <= .now {
                Button(action: onLog) {
                    Label("Log", systemImage: "checkmark.seal")
                }
                .tint(.brandForest)
            }
        }
        .contextMenu {
            if meal.date <= .now {
                Button(action: onLog) {
                    Label("Log This Meal in History", systemImage: "checkmark.seal")
                }
            }
            if meal.orderReminderDate != nil {
                Button(role: .destructive, action: onCancelReminder) {
                    Label("Cancel Reminder", systemImage: "bell.slash")
                }
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: MealSuggestion
    let members: [FamilyMember]
    let onVote: () -> Void
    let onAdopt: () -> Void
    let onRemove: () -> Void

    private var proposer: FamilyMember? {
        members.first(where: { $0.id == suggestion.proposedByMemberID })
    }

    /// Same icon/color convention as `PlannedMealRow` once something's
    /// actually decided — a recipe suggestion, an eat-out one, and an
    /// order-in one all read distinctly at a glance here too.
    private var iconName: String {
        if suggestion.recipe != nil { return "frying.pan" }
        return suggestion.isOrderIn ? "bag" : "fork.knife"
    }
    private var iconColor: Color {
        if suggestion.recipe != nil { return .brandForest }
        return suggestion.isOrderIn ? .brandHoney : .brandTerracotta
    }

    var body: some View {
        HStack {
            if let proposer {
                MemberBadgeView(member: proposer, size: 22)
            }
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading) {
                Text(suggestion.displayTitle)
                if let note = suggestion.note, !note.isEmpty {
                    Text(note).font(.brandCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onVote) {
                Label("\(suggestion.voteCount)", systemImage: "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            Button("Use This", action: onAdopt)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .swipeActions(edge: .trailing) {
            // See `PlannedMealRow`'s identical swipe action above for why
            // this needs an explicit `.tint(.red)`.
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove Suggestion", systemImage: "trash")
            }
        }
    }
}
