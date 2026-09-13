import SwiftUI
import SwiftData

@main
struct HomeEatsApp: App {
    let modelContainer: ModelContainer
    @StateObject private var reminderRouter = PlanningReminderRouter()
    @StateObject private var activeUserSession = ActiveUserSession()
    /// The accounts/friends/groups/sharing session (mandatory — `RootView`
    /// gates the whole app behind it) — see its own doc comment for why
    /// this is deliberately a separate object from
    /// `activeUserSession` above. Injected into the environment the same
    /// way, so any view under `RootView` (including sheets presented from
    /// deep inside it, like `AccountSignInView` or `RecipeSharePickerSheet`)
    /// can read it with `@EnvironmentObject`.
    @StateObject private var accountSession = AccountSession()
    /// Which group's shared plan/grocery list the main tabs render — the
    /// app-creation pivot's new organizing concept, replacing
    /// `FamilyMember`/`ActiveUserSession` as what the main Plan/Grocery tabs
    /// key off of (see `ActiveGroupSession`'s own doc comment for the full
    /// reasoning). Injected the same way as the two session objects above
    /// so any view under `RootView` can read it with `@EnvironmentObject`.
    @StateObject private var activeGroupSession = ActiveGroupSession()

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
            HistoricalGroceryItem.self,
            GroceryReminder.self,
            // Phase 4 — local, offline-capable mirrors of a group's shared
            // meal plan/grocery list (see `GroupSyncService`'s doc comment
            // for the full sync design). Separate types from the personal
            // planning models above them in this list, not additional
            // fields on those — see each model's own doc comment for why.
            GroupPlannedMeal.self,
            GroupMealSuggestion.self,
            GroupSharedGroceryItem.self,
            // Phase 4 continued — group-scoped "My Layout" aisles and
            // grocery history (see HomeEats/Models/GroupGroceryLayout.swift),
            // the group counterparts of the personal StoreAisle/
            // HistoricalGroceryItem models above. (A third entry used to be
            // here, GroupStapleItem.self, for the group-scoped standing
            // "staples" template list — removed outright per user feedback;
            // see that model's former doc comment, preserved as a note on
            // GroupStoreAisle in GroupGroceryLayout.swift.)
            GroupStoreAisle.self,
            GroupGroceryHistoryEntry.self
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
        GroceryLayoutOrderBackfill.runIfNeeded(context: modelContainer.mainContext)
        RejectedGroceryItemCleanup.runIfNeeded(context: modelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.brandOlive)
                .environment(\.font, .brandBody)
                // The brand palette (BrandTheme.swift) is a single fixed set
                // of colors, not a light+dark pair — Cream nav bars, Cream
                // table backgrounds, etc. are pinned to one literal color
                // regardless of appearance. Without this, the *rest* of the
                // system chrome (the search bar under a nav bar, the
                // keyboard, sheets, anything using default system colors)
                // still follows the device's Dark Mode setting independently
                // — which is exactly the seam/glitch reported "above Your
                // Restaurants": a light Cream nav bar sitting right next to
                // a dark-mode search bar. Pinning the whole app to light
                // keeps everything consistent. Revisit if the brand ever
                // gets a real dark variant.
                .preferredColorScheme(.light)
                .environmentObject(reminderRouter)
                .environmentObject(activeUserSession)
                .environmentObject(accountSession)
                .environmentObject(activeGroupSession)
                .task {
                    reminderRouter.install()
                    await scheduleReminderIfConfigured()
                    await scheduleGroceryRemindersIfConfigured()
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

    /// Same reasoning as `scheduleReminderIfConfigured()` above, for the
    /// (possibly several) grocery-run reminders — `GroceryRemindersSettingsView`'s
    /// add/edit/remove handlers are the only other call sites, so this is
    /// what re-arms them across an app relaunch.
    @MainActor
    private func scheduleGroceryRemindersIfConfigured() async {
        let descriptor = FetchDescriptor<GroceryReminder>()
        guard let reminders = try? modelContainer.mainContext.fetch(descriptor) else { return }
        await NotificationScheduler.rescheduleGroceryReminders(reminders)
    }
}
