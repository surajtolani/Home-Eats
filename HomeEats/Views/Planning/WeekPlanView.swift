import SwiftUI
import SwiftData

struct WeekPlanView: View {
    @Binding var showPlanningFlow: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayPlan.date) private var allDayPlans: [DayPlan]
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]
    @Query private var staples: [StapleItem]

    @State private var weekOffset: Int = 0

    private var calendar: Calendar { Calendar.current }

    private var displayedWeekStart: Date {
        let base = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return calendar.startOfWeek(containing: base)
    }

    private var daysInWeek: [Date] {
        calendar.daysOfWeek(containing: displayedWeekStart)
    }

    var body: some View {
        List {
            Section {
                weekNavigator
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(daysInWeek, id: \.self) { day in
                    NavigationLink {
                        DayPlanDetailView(dayPlan: dayPlan(for: day))
                    } label: {
                        DayRow(dayPlan: dayPlan(for: day), members: members)
                    }
                }
            } header: {
                Text(weekRangeLabel)
            }

            Section {
                Button {
                    GroceryListBuilder.regenerate(
                        weekStart: displayedWeekStart,
                        dayPlans: daysInWeek.map(dayPlan(for:)),
                        staples: staples,
                        in: modelContext
                    )
                } label: {
                    Label("Update Grocery List for This Week", systemImage: "cart.badge.plus")
                }
            }
        }
        .navigationTitle("This Week")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ActiveUserMenu()
            }
        }
        .fullScreenCover(isPresented: $showPlanningFlow) {
            PlanningReminderFlowView()
        }
        .task(id: displayedWeekStart) {
            ensureDayPlansExist(for: daysInWeek)
        }
    }

    /// Inserts a `DayPlan` for any date in `dates` that doesn't have one yet.
    /// Done as an explicit side effect (rather than lazily inside `body`) so
    /// we never mutate the model context while SwiftUI is still computing a view.
    private func ensureDayPlansExist(for dates: [Date]) {
        for date in dates {
            let normalized = DayPlan.normalize(date)
            if !allDayPlans.contains(where: { $0.date.isSameDay(as: normalized) }) {
                modelContext.insert(DayPlan(date: normalized))
            }
        }
    }

    private var weekNavigator: some View {
        HStack {
            Button {
                weekOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Button("This Week") { weekOffset = 0 }
                .font(.subheadline)
                .disabled(weekOffset == 0)
            Spacer()
            Button {
                weekOffset += 1
            } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.borderless)
    }

    private var weekRangeLabel: String {
        guard let last = daysInWeek.last, let first = daysInWeek.first else { return "" }
        return "\(first.formatted(Date.monthDay)) – \(last.formatted(Date.monthDay))"
    }

    /// Finds the persisted DayPlan for a date. `ensureDayPlansExist(for:)`
    /// (run from `.task`) guarantees this exists for any date currently on
    /// screen; the freshly-constructed fallback only covers the brief first
    /// frame before that task has run.
    private func dayPlan(for date: Date) -> DayPlan {
        let normalized = DayPlan.normalize(date)
        return allDayPlans.first { $0.date.isSameDay(as: normalized) } ?? DayPlan(date: normalized)
    }
}

private struct DayRow: View {
    let dayPlan: DayPlan
    let members: [FamilyMember]

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(dayPlan.date.formatted(Date.weekdayFull))
                    .font(.headline)
                Text(dayPlan.date.formatted(Date.monthDay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                statusLine
                if !dayPlan.suggestions.isEmpty && !dayPlan.isDecided {
                    HStack(spacing: -6) {
                        ForEach(proposerBadges, id: \.id) { member in
                            MemberBadgeView(member: member, size: 20)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch dayPlan.kind {
        case .unplanned:
            Text(dayPlan.suggestions.isEmpty ? "Not planned" : "\(dayPlan.suggestions.count) suggestion(s)")
                .foregroundStyle(.secondary)
        case .homeCookedRecipe:
            Label(dayPlan.decidedRecipe?.title ?? "Recipe", systemImage: "frying.pan")
        case .eatingOut:
            Label(dayPlan.decidedRestaurant?.name ?? "Restaurant", systemImage: "fork.knife")
        }
    }

    private var proposerBadges: [FamilyMember] {
        let ids = Set(dayPlan.suggestions.map(\.proposedByMemberID))
        return members.filter { ids.contains($0.id) }
    }
}
