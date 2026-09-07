import SwiftUI
import SwiftData

@main
struct HomeEatsApp: App {
    let modelContainer: ModelContainer
    @StateObject private var reminderRouter = PlanningReminderRouter()
    @StateObject private var activeUserSession = ActiveUserSession()

    init() {
        // Nav bar / tab bar chrome is drawn by UIKit, which SwiftUI's
        // `.font`/`.tint` modifiers on `RootView` below don't reach — this
        // is the one-time hook that applies the Nunito/brand-color look to it.
        BrandAppearance.apply()

        let schema = Schema([
            FamilyMember.self,
            Recipe.self,
            Restaurant.self,
            PlannedMeal.self,
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
        //
        // An explicit `url:` (rather than SwiftData's default location) is
        // what makes the recovery below possible — we need to know exactly
        // which file to remove if the schema on disk can't be opened.
        let storeURL = Self.storeURL
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A schema change SwiftData's lightweight migration can't bridge
            // (this project has already made one: dropping `DayPlan` for
            // `PlannedMeal`, which adds non-optional attributes with no
            // default) would otherwise `fatalError` here on every launch —
            // permanently bricking the app for anyone who had an earlier
            // build installed, with no recovery but a manual delete/reinstall.
            // Pre-release, with no real user data at stake, resetting local
            // storage and starting fresh is the safer failure mode. This is
            // an MVP tradeoff, not a real migration strategy — shipping this
            // behavior for good means every future schema change needs an
            // actual `SchemaMigrationPlan` instead, or this silently deletes
            // real users' data on an incompatible update.
            print("ModelContainer creation failed (\(error)); resetting local store.")
            Self.deleteStore(at: storeURL)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Failed to create ModelContainer even after resetting local storage: \(error)")
            }
        }

        SampleDataSeeder.seedIfNeeded(context: modelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.brandOlive)
                .environment(\.font, .brandBody)
                .environmentObject(reminderRouter)
                .environmentObject(activeUserSession)
                .task {
                    reminderRouter.install()
                    await scheduleReminderIfConfigured()
                }
        }
        .modelContainer(modelContainer)
    }

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "HomeEats.store")
    }

    private static func deleteStore(at url: URL) {
        let fileManager = FileManager.default
        // SwiftData's SQLite store keeps WAL/SHM sidecar files alongside the
        // main file; all three need to go together or the store is left
        // inconsistent.
        for suffix in ["", "-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: url.path + suffix)
            try? fileManager.removeItem(at: sidecarURL)
        }
    }

    /// Arms the weekly planning notification on every launch using whatever
    /// `AppSettings` currently says. Without this, a fresh install has
    /// `reminderEnabled: true` from the seeder but nothing ever actually
    /// calls `NotificationScheduler` — the only other call sites are
    /// `SettingsView`'s field-change handlers, so the reminder silently
    /// never fires unless the user happens to open Settings and edit
    /// something. `reschedule(using:)` cancels-then-recreates, so calling it
    /// on every launch is safe and idempotent.
    @MainActor
    private func scheduleReminderIfConfigured() async {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? modelContainer.mainContext.fetch(descriptor).first else { return }
        await NotificationScheduler.reschedule(using: settings)
    }
}
