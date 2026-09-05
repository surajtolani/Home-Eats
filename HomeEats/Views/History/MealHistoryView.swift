import SwiftUI
import SwiftData

struct MealHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealHistoryEntry.date, order: .reverse) private var history: [MealHistoryEntry]
    @Query private var recipes: [Recipe]
    @Query private var restaurants: [Restaurant]
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    @State private var showAddSheet = false

    var body: some View {
        List {
            if history.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock",
                    description: Text("Log meals as you make them (from a day's plan, or right here) to build up recommendations.")
                )
            }
            ForEach(history) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(title(for: entry)).font(.headline)
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let rating = entry.rating {
                        Text(emoji(for: rating))
                    }
                    if let memberID = entry.madeByMemberID, let member = members.first(where: { $0.id == memberID }) {
                        MemberBadgeView(member: member, size: 20)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(history[index]) }
            }
        }
        .navigationTitle("Meal History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddHistoryEntrySheet()
        }
    }

    private func title(for entry: MealHistoryEntry) -> String {
        if let id = entry.recipeID, let recipe = recipes.first(where: { $0.id == id }) {
            return recipe.title
        }
        if let id = entry.restaurantID, let restaurant = restaurants.first(where: { $0.id == id }) {
            return restaurant.name
        }
        return "Meal"
    }

    private func emoji(for rating: MealRating) -> String {
        switch rating {
        case .liked: return "😋"
        case .neutral: return "🙂"
        case .disliked: return "😖"
        }
    }
}

private struct AddHistoryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var date = Date.now
    @State private var pickedRecipe: Recipe?
    @State private var rating: MealRating = .liked
    @State private var showRecipePicker = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Button {
                    showRecipePicker = true
                } label: {
                    HStack {
                        Text("Recipe")
                        Spacer()
                        Text(pickedRecipe?.title ?? "Choose")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Rating", selection: $rating) {
                    Text("😖").tag(MealRating.disliked)
                    Text("🙂").tag(MealRating.neutral)
                    Text("😋").tag(MealRating.liked)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("Log a Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(pickedRecipe == nil)
                }
            }
            .sheet(isPresented: $showRecipePicker) {
                RecipePickerSheet { recipe in pickedRecipe = recipe }
            }
        }
    }

    private func save() {
        guard let pickedRecipe else { return }
        let entry = MealHistoryEntry(
            date: date,
            recipeID: pickedRecipe.id,
            rating: rating,
            madeByMemberID: activeUserSession.activeMemberID
        )
        modelContext.insert(entry)
        dismiss()
    }
}
