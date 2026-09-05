import SwiftUI
import SwiftData

struct DayPlanDetailView: View {
    @Bindable var dayPlan: DayPlan

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    @State private var showRecipePicker = false
    @State private var showRestaurantPicker = false
    @State private var showRecipeSuggestionPicker = false
    @State private var showRestaurantSuggestionPicker = false
    @State private var showCookedLogSheet = false

    var body: some View {
        Form {
            Section {
                if dayPlan.isDecided {
                    decidedSummary
                } else {
                    Text("No decision yet for this day.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(dayPlan.date.formatted(.dateTime.weekday(.wide).month().day()))
            }

            Section("Set the Plan") {
                Button {
                    showRecipePicker = true
                } label: {
                    Label("Cook a Recipe", systemImage: "frying.pan")
                }
                Button {
                    showRestaurantPicker = true
                } label: {
                    Label("Eat Out", systemImage: "fork.knife")
                }
                if dayPlan.isDecided {
                    Button(role: .destructive) {
                        dayPlan.clearDecision()
                    } label: {
                        Label("Clear Decision", systemImage: "xmark.circle")
                    }
                }
            }

            Section {
                if dayPlan.suggestions.isEmpty {
                    Text("No one has suggested anything for this day yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dayPlan.suggestions.sorted(by: { $0.voteCount > $1.voteCount })) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        members: members,
                        onVote: { toggleVote(on: suggestion) },
                        onAdopt: { adopt(suggestion) }
                    )
                }
                .onDelete { offsets in
                    let sorted = dayPlan.suggestions.sorted(by: { $0.voteCount > $1.voteCount })
                    for index in offsets { modelContext.delete(sorted[index]) }
                }

                Menu {
                    Button("Suggest a Recipe") { showRecipeSuggestionPicker = true }
                    Button("Suggest a Restaurant") { showRestaurantSuggestionPicker = true }
                } label: {
                    Label("Add Suggestion", systemImage: "plus.bubble")
                }
            } header: {
                Text("Suggestions & Votes")
            } footer: {
                Text("Anyone in the family can propose a meal for this day; votes help the group pick.")
            }

            if dayPlan.isDecided && dayPlan.date <= .now {
                Section {
                    Button {
                        showCookedLogSheet = true
                    } label: {
                        Label("Log This Meal in History", systemImage: "checkmark.seal")
                    }
                }
            }
        }
        .navigationTitle(dayPlan.date.formatted(Date.weekdayFull))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet { recipe in
                dayPlan.finalize(recipe: recipe, by: activeUserSession.activeMemberID)
            }
        }
        .sheet(isPresented: $showRestaurantPicker) {
            RestaurantPickerSheet { restaurant in
                dayPlan.finalize(restaurant: restaurant, by: activeUserSession.activeMemberID)
            }
        }
        .sheet(isPresented: $showRecipeSuggestionPicker) {
            RecipePickerSheet { recipe in
                addSuggestion(recipe: recipe)
            }
        }
        .sheet(isPresented: $showRestaurantSuggestionPicker) {
            RestaurantPickerSheet { restaurant in
                addSuggestion(restaurant: restaurant)
            }
        }
        .sheet(isPresented: $showCookedLogSheet) {
            LogMealSheet(dayPlan: dayPlan)
        }
    }

    @ViewBuilder
    private var decidedSummary: some View {
        HStack {
            switch dayPlan.kind {
            case .homeCookedRecipe:
                if let recipe = dayPlan.decidedRecipe {
                    NavigationLink(recipe.title) {
                        RecipeDetailView(recipe: recipe)
                    }
                }
            case .eatingOut:
                Text(dayPlan.decidedRestaurant?.name ?? "Restaurant")
            case .unplanned:
                EmptyView()
            }
            Spacer()
            if let memberID = dayPlan.decidedByMemberID, let member = members.first(where: { $0.id == memberID }) {
                MemberBadgeView(member: member)
            }
        }
    }

    private func toggleVote(on suggestion: MealSuggestion) {
        guard let memberID = activeUserSession.activeMemberID else { return }
        suggestion.toggleVote(for: memberID)
    }

    private func adopt(_ suggestion: MealSuggestion) {
        if let recipe = suggestion.recipe {
            dayPlan.finalize(recipe: recipe, by: activeUserSession.activeMemberID)
        } else if let restaurant = suggestion.restaurant {
            dayPlan.finalize(restaurant: restaurant, by: activeUserSession.activeMemberID)
        }
    }

    private func addSuggestion(recipe: Recipe? = nil, restaurant: Restaurant? = nil) {
        guard let memberID = activeUserSession.activeMemberID ?? members.first?.id else { return }
        let suggestion = MealSuggestion(proposedByMemberID: memberID, recipe: recipe, restaurant: restaurant)
        suggestion.dayPlan = dayPlan
        modelContext.insert(suggestion)
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
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onVote()
            } label: {
                Label("\(suggestion.voteCount)", systemImage: "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            Button("Use This") { onAdopt() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
