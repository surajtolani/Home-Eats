import SwiftUI
import SwiftData

/// One day's plan, broken into Breakfast / Lunch / Dinner / Other. Each slot
/// can hold more than one decided meal (a dinner plan *and* an ice-cream run
/// afterward both live in the same day, different slots — or even the same
/// slot, if the family genuinely can't decide between two options), plus its
/// own suggestions and votes.
struct DayDetailView: View {
    let date: Date

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \PlannedMeal.decidedAt) private var allPlannedMeals: [PlannedMeal]
    @Query(sort: \MealSuggestion.createdAt) private var allSuggestions: [MealSuggestion]
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    @State private var activeSheet: SheetAction?

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
        Form {
            ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                slotSection(slot)
            }
        }
        .navigationTitle(date.formatted(Date.weekdayFull))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { action in
            sheetContent(for: action)
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
                    onRemove: { modelContext.delete(meal) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 0, trailing: 16))
            }
            ForEach(suggestions(for: slot)) { suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    members: members,
                    onVote: { toggleVote(on: suggestion) },
                    onAdopt: { adopt(suggestion) }
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
                    Button { activeSheet = .suggestRecipe(slot) } label: {
                        Label("Suggest a Recipe", systemImage: "bubble.left")
                    }
                    Button { activeSheet = .suggestRestaurant(slot) } label: {
                        Label("Suggest a Restaurant", systemImage: "bubble.left")
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

    @ViewBuilder
    private func sheetContent(for action: SheetAction) -> some View {
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
        case .suggestRecipe(let slot):
            RecipePickerSheet { recipe in
                addSuggestion(slot: slot, recipe: recipe)
            }
        case .suggestRestaurant(let slot):
            RestaurantPickerSheet { restaurant in
                addSuggestion(slot: slot, restaurant: restaurant)
            }
        case .logMeal(let meal):
            LogMealSheet(meal: meal)
        }
    }

    private func decide(slot: MealSlot, recipe: Recipe? = nil, restaurant: Restaurant? = nil, isOrderIn: Bool = false) {
        let meal = PlannedMeal(
            date: normalizedDate,
            slot: slot,
            recipe: recipe,
            restaurant: restaurant,
            isOrderIn: isOrderIn,
            decidedByMemberID: activeUserSession.activeMemberID
        )
        modelContext.insert(meal)
    }

    private func addSuggestion(slot: MealSlot, recipe: Recipe? = nil, restaurant: Restaurant? = nil) {
        guard let memberID = activeUserSession.activeMemberID ?? members.first?.id else { return }
        let suggestion = MealSuggestion(
            date: normalizedDate,
            slot: slot,
            proposedByMemberID: memberID,
            recipe: recipe,
            restaurant: restaurant
        )
        modelContext.insert(suggestion)
    }

    private func toggleVote(on suggestion: MealSuggestion) {
        guard let memberID = activeUserSession.activeMemberID else { return }
        suggestion.toggleVote(for: memberID)
    }

    private func adopt(_ suggestion: MealSuggestion) {
        decide(slot: suggestion.slot, recipe: suggestion.recipe, restaurant: suggestion.restaurant)
        modelContext.delete(suggestion)
    }
}

/// Identifies which sheet is presented, and with what context, from a single
/// `@State` var rather than a pile of booleans (each day has 4 slots × 4
/// possible add/suggest actions, plus per-meal logging).
private enum SheetAction: Identifiable {
    case addRecipe(MealSlot)
    case addRestaurant(MealSlot)
    case orderIn(MealSlot)
    case suggestRecipe(MealSlot)
    case suggestRestaurant(MealSlot)
    case logMeal(PlannedMeal)

    var id: String {
        switch self {
        case .addRecipe(let slot): return "addRecipe-\(slot.rawValue)"
        case .addRestaurant(let slot): return "addRestaurant-\(slot.rawValue)"
        case .orderIn(let slot): return "orderIn-\(slot.rawValue)"
        case .suggestRecipe(let slot): return "suggestRecipe-\(slot.rawValue)"
        case .suggestRestaurant(let slot): return "suggestRestaurant-\(slot.rawValue)"
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
            Spacer()
            if let member {
                MemberBadgeView(member: member, size: 20)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
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

    private var proposer: FamilyMember? {
        members.first(where: { $0.id == suggestion.proposedByMemberID })
    }

    var body: some View {
        HStack {
            if let proposer {
                MemberBadgeView(member: proposer, size: 22)
            }
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
    }
}
