import SwiftUI
import SwiftData

@main
struct HomeEatsApp: App {
    /// See `HomeEatsAppDelegate`'s own doc comment for why this SwiftUI app
    /// needs one at all — purely to reach the APNs registration callbacks.
    @UIApplicationDelegateAdaptor(HomeEatsAppDelegate.self) private var appDelegate
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
    /// The signed-in caller's own "things waiting on my response" feed
    /// (Phase 5, Part 3 — see its own doc comment) — backs the notification
    /// bell's badge (`GroupTopBar`) and `NotificationsView`'s list.
    /// Injected the same way as the three session objects above so either
    /// can read it with `@EnvironmentObject`.
    @StateObject private var notificationsSession = NotificationsSession()

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
            // Phase 4 continued — group-scoped "My Layout" aisles (see
            // HomeEats/Models/GroupGroceryLayout.swift), the group
            // counterpart of the personal StoreAisle model above. (Two
            // other entries used to be here: GroupStapleItem.self, for the
            // group-scoped standing "staples" template list, and
            // GroupGroceryHistoryEntry.self, for the group-shared "past
            // groceries" catalog — both removed outright per user feedback;
            // see GroupStoreAisle's doc comment in GroupGroceryLayout.swift
            // for both removal notes.)
            GroupStoreAisle.self
        ])
        // Local-first storage per spec: everything lives on-device by
        // default. `cloudKitDatabase: .none` keeps that explicit; flipping
        // this to `.automatic` (plus enabling the iCloud/CloudKit capability
        // in Xcode) is the whole phase-2 sync story described in the spec.
        //
        // An explicit `url:` (rather than SwiftData's default location) is
        // what makes the recovery below possible — we need to know exactly
        // which file to quarantine if the schema on disk can't be opened.
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
            // Resetting local storage and starting fresh is the safer
            // failure mode than bricking the app outright. This is still an
            // MVP tradeoff, not a real migration strategy — shipping this
            // behavior for good means every future schema change needs an
            // actual `SchemaMigrationPlan` instead.
            //
            // **Not a silent, irrecoverable delete anymore** — direct user
            // question: "is there a way to make sure that we don't have an
            // issue where the images suddenly disappear and we can't get it
            // back." This exact mechanism is a real, previously-confirmed
            // cause of that (see `GroupSharedGroceryItem.quantityCount`'s own
            // doc comment on the incident that motivated `PersonalLibrarySyncService`
            // in the first place) — a bad migration used to hard-delete the
            // WAL/SHM/store files outright, so anything not already backed
            // up to the account (a personal-only recipe/restaurant never
            // synced, or any local-only meal-plan/grocery data, which has no
            // backend copy at all) was gone for good, not just until the
            // next sync. `moveStoreAside(from:)` renames the old store files
            // aside (timestamped, so a repeat failure never overwrites an
            // earlier quarantined copy) instead of deleting them — the app
            // still starts fresh with a new, empty store either way (this
            // doesn't change what the person sees at launch), but the old
            // data file itself survives on disk, recoverable later by
            // inspecting the device's file system rather than gone the
            // instant this runs.
            print("ModelContainer creation failed (\(error)); quarantining local store and starting fresh.")
            Self.moveStoreAside(from: storeURL)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Failed to create ModelContainer even after quarantining local storage: \(error)")
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
                .environmentObject(notificationsSession)
                .task {
                    reminderRouter.install()
                    await scheduleReminderIfConfigured()
                    await scheduleGroceryRemindersIfConfigured()
                    // Real push notifications (a friend request, a group
                    // invite) — see `PushNotificationService`'s own doc
                    // comment. Unconditional at launch, same "ask once, up
                    // front" pattern the two calls above already use for
                    // the local reminder; `registerWithBackendIfPossible()`
                    // (called again once the device token actually arrives,
                    // and again right after sign-in) is what actually needs
                    // a signed-in account, not this.
                    await PushNotificationService.requestAuthorizationAndRegisterForRemoteNotifications()
                }
        }
        .modelContainer(modelContainer)
    }

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "HomeEats.store")
    }

    /// Renames the old store's main file and its WAL/SHM sidecars aside
    /// (all three move together, or the quarantined copy would itself be
    /// left inconsistent) into a `QuarantinedStores` subfolder, timestamped
    /// so a second migration failure later never overwrites an earlier
    /// quarantined copy. Deliberately a *move*, not a delete — see the
    /// call site's own doc comment for why. Best-effort: if even the move
    /// fails (e.g. a truly unreadable/corrupt file `FileManager` can't
    /// touch), this still leaves the original file in place rather than
    /// force-deleting it, and `ModelContainer` creation right after this
    /// call simply gets whatever fresh store it can — same fallback either
    /// way.
    private static func moveStoreAside(from url: URL) {
        let fileManager = FileManager.default
        let quarantineDir = url.deletingLastPathComponent().appending(path: "QuarantinedStores")
        try? fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL = quarantineDir.appending(path: "\(timestamp)-\(url.lastPathComponent)\(suffix)")
            try? fileManager.moveItem(at: sourceURL, to: destinationURL)
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
