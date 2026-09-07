import SwiftUI
import SwiftData

@main
struct HomeEatsApp: App {
    let modelContainer: ModelContainer
    @StateObject private var reminderRouter = PlanningReminderRouter()
    @StateObject private var activeUserSession = ActiveUserSession()

    init() {
        let schema = Schema([
            FamilyMember.self,
            Recipe.self,
            Restaurant.self,
            DayPlan.self,
            MealSuggestion.self,
            GroceryItem.self,
            ProductOption.self,
            StapleItem.self,
            MealHistoryEntry.self,
            AppSettings.self,
            StoreAisle.self,
            ItemAisleAssignment.self,
            HistoricalGroceryItem.self
        ])
        // Local-first storage per spec: everything lives on-device by
        // default. `cloudKitDatabase: .none` keeps that explicit; flipping
        // this to `.automatic` (plus enabling the iCloud/CloudKit capability
        // in Xcode) is the whole phase-2 sync story described in the spec.
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        SampleDataSeeder.seedIfNeeded(context: modelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(reminderRouter)
                .environmentObject(activeUserSession)
                .task {
                    reminderRouter.install()
                }
        }
        .modelContainer(modelContainer)
    }
}
