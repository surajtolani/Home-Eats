import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query private var settingsRows: [AppSettings]
    @Query(sort: \GroceryReminder.createdAt) private var groceryReminders: [GroceryReminder]
    // Unfiltered — same "fetch everything, filter `syncState` in Swift"
    // caution as `GroupSyncService`'s own local fetches (see its doc
    // comments) — used only to decide whether to show the sign-out warning
    // below, not for display.
    @Query private var groupPlannedMeals: [GroupPlannedMeal]
    @Query private var groupMealSuggestions: [GroupMealSuggestion]
    @Query private var groupGroceryItems: [GroupSharedGroceryItem]
    // Phase 4 — "My Layout" aisles can carry a pending
    // create/rename/reorder/toggle too (see `GroupStoreAisle`'s own
    // `syncState`), so they have to be checked here the same as the three
    // models above — otherwise a group member who only, say, renamed an
    // aisle offline would sign out with no warning at all, and
    // `GroupSyncService.purgeAllLocalGroupData` (which purges this
    // unconditionally, same as the rest) would silently drop it.
    // (Two former sibling queries here — `groupStaples: [GroupStapleItem]`
    // and `groupGroceryHistory: [GroupGroceryHistoryEntry]` (which had no
    // pending state of its own to lose in the first place) — were removed
    // along with the rest of the standing "staples" template-list feature
    // and the group-shared "past groceries" catalog, respectively; see
    // `GroupStoreAisle`'s doc comment in
    // HomeEats/Models/GroupGroceryLayout.swift for both removal notes.)
    @Query private var groupAisles: [GroupStoreAisle]

    @State private var reminderTime: Date = Calendar.current.date(
        from: DateComponents(hour: 18, minute: 0)
    ) ?? .now
    @State private var showSignIn = false
    @State private var showUnsyncedSignOutWarning = false

    /// Whether any group-sync row is still waiting to reach the server —
    /// used only to decide whether signing out needs a confirmation first;
    /// see `GroupSyncService.purgeAllLocalGroupData`'s doc comment for why
    /// sign-out purges these rows unconditionally regardless of this check.
    private var hasUnsyncedGroupChanges: Bool {
        groupPlannedMeals.contains { $0.syncState != .synced }
            || groupMealSuggestions.contains { $0.syncState != .synced }
            || groupGroceryItems.contains { $0.syncState != .synced }
            || groupAisles.contains { $0.syncState != .synced }
    }

    // `settings` is read several times per `body` pass (the toggle, the day
    // picker, the reminder-time handler...). Inserting a new row from inside
    // it — as this used to do — mutates the model context, and therefore
    // `@Query settingsRows`, in the middle of that same body evaluation:
    // exactly the "modifying state during view update" pattern that's
    // caused real bugs elsewhere in this app. `SampleDataSeeder` already
    // guarantees this row exists at launch, so in practice `settingsRows`
    // is never actually empty here — `ensureSettingsExist()` (run from
    // `.task`, a safe point to mutate state) is just a backstop for the
    // unlikely case that seeding failed; `settings` itself only ever reads.
    private var settings: AppSettings {
        settingsRows.first ?? AppSettings()
    }

    private func ensureSettingsExist() {
        guard settingsRows.isEmpty else { return }
        modelContext.insert(AppSettings())
    }

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    var body: some View {
        Form {
            // Sign-in is mandatory — `RootView` gates the whole app behind
            // it, so anyone looking at this screen is already signed in
            // (the `else` branches below only ever show transiently, right
            // after launch, while `GET /me` is still resolving). This
            // section is where that account's identity, friends, and
            // groups live, not a separate opt-in on top of an otherwise
            // account-free app the way it used to be — see AccountSession's
            // doc comment for the history.
            Section {
                if accountSession.isSignedIn, let user = accountSession.currentUser {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayNameOrPhoneNumber)
                            .font(.brandHeadline)
                        // Only show the phone number as a subtitle when
                        // there's an actual name above it to distinguish it
                        // from — otherwise `displayNameOrPhoneNumber`
                        // already fell back to showing it up top, and
                        // repeating it here would just be the same string
                        // twice.
                        if user.displayName?.isEmpty == false {
                            Text(user.phoneNumber)
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        EditProfileView()
                    } label: {
                        Label("Edit Profile", systemImage: "person.crop.circle")
                    }
                    Button("Sign Out", role: .destructive) {
                        // Signing out purges every locally-cached group-sync
                        // row unconditionally, pending or not — see
                        // `GroupSyncService.purgeAllLocalGroupData`'s doc
                        // comment for why. Warn first if that would actually
                        // lose something, so a genuinely offline edit isn't
                        // silently dropped with no chance to notice.
                        if hasUnsyncedGroupChanges {
                            showUnsyncedSignOutWarning = true
                        } else {
                            accountSession.signOut()
                        }
                    }
                } else if accountSession.isSignedIn {
                    // A token is stored but GET /me hasn't resolved yet
                    // (see AccountSession.init) — a brief state right after
                    // launch, not worth its own error handling.
                    HStack {
                        ProgressView()
                        Text("Loading your account…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Sign In") { showSignIn = true }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Your account is what your friends and groups see you as. Everything you do still works fully offline — this just needs a working connection the first time, and whenever you sync with a shared group.")
            }

            // Its own section, not nested under "Account" — friends and
            // groups are what most people are actually here to use day to
            // day, not account-management chores like signing out.
            if accountSession.isSignedIn {
                Section("Friends & Groups") {
                    NavigationLink {
                        FriendsListView()
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                    NavigationLink {
                        GroupsListView()
                    } label: {
                        Label("Groups", systemImage: "person.3")
                    }
                }
            }

            // The old "Household name" field lived here — removed as part
            // of the app-creation pivot: a *group* (with a real name of its
            // own, set at creation and visible throughout "Friends &
            // Groups" above and the main Plan/Grocery tabs' switcher) is
            // now the thing that organizes shared planning, making a
            // second, disconnected "household name" free-text field redundant
            // and confusing next to it. `AppSettings.householdName` itself
            // is left in place (unused now, but SwiftData model changes are
            // outside this cleanup's scope — see this task's own final
            // report) rather than touched here.

            Section {
                Toggle("Weekly Planning Reminder", isOn: Binding(
                    get: { settings.reminderEnabled },
                    set: { newValue in
                        settings.reminderEnabled = newValue
                        Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                    }
                ))

                if settings.reminderEnabled {
                    Picker("Day", selection: Binding(
                        get: { settings.reminderWeekday },
                        set: { newValue in
                            settings.reminderWeekday = newValue
                            Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                        }
                    )) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(weekdaySymbols[weekday - 1]).tag(weekday)
                        }
                    }

                    DatePicker(
                        "Time",
                        selection: $reminderTime,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: reminderTime) { _, newValue in
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        settings.reminderHour = comps.hour ?? 18
                        settings.reminderMinute = comps.minute ?? 0
                        Task { @MainActor in await NotificationScheduler.reschedule(using: settings) }
                    }
                }
            } header: {
                Text("Planning Reminder")
            } footer: {
                Text("We'll send a notification to start planning the week's meals and eating-out nights.")
            }

            Section {
                if groceryReminders.isEmpty {
                    Text("No grocery reminders set.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groceryReminders) { reminder in
                    GroceryReminderRow(reminder: reminder, onChange: rescheduleGroceryReminders)
                }
                .onDelete { offsets in
                    for index in offsets { modelContext.delete(groceryReminders[index]) }
                    rescheduleGroceryReminders()
                }
                Button {
                    addGroceryReminder()
                } label: {
                    Label("Add a Reminder", systemImage: "plus")
                }
            } header: {
                Text("Grocery Reminders")
            } footer: {
                Text("Add one reminder for each time your family typically shops or orders groceries — some households do this more than once a week.")
            }
        }
        .navigationTitle("Settings")
        .task {
            ensureSettingsExist()
            reminderTime = Calendar.current.date(
                from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)
            ) ?? .now
        }
        .sheet(isPresented: $showSignIn) {
            AccountSignInView()
        }
        .confirmationDialog(
            "You have unsynced changes",
            isPresented: $showUnsyncedSignOutWarning,
            titleVisibility: .visible
        ) {
            Button("Sign Out Anyway", role: .destructive) {
                accountSession.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some group meal-plan or grocery-list changes haven't synced yet. Signing out now will lose them.")
        }
    }

    private func addGroceryReminder() {
        modelContext.insert(GroceryReminder())
        rescheduleGroceryReminders()
    }

    private func rescheduleGroceryReminders() {
        Task { @MainActor in
            await NotificationScheduler.rescheduleGroceryReminders(groceryReminders)
        }
    }
}

/// One row of the "Grocery Reminders" section — an enabled toggle, a
/// weekday picker, and a time picker, all bound directly to one
/// `GroceryReminder`. Its own local `@State` for the time picker (mirroring
/// the single planning-reminder's `reminderTime` above) since `DatePicker`
/// needs a full `Date` to bind to, not separate hour/minute ints.
private struct GroceryReminderRow: View {
    @Bindable var reminder: GroceryReminder
    let onChange: () -> Void

    @State private var time: Date = .now

    private let weekdaySymbols = Calendar.current.weekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { reminder.isEnabled },
                set: { reminder.isEnabled = $0; onChange() }
            )) {
                Text(reminder.isEnabled ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }

            if reminder.isEnabled {
                Picker("Day", selection: Binding(
                    get: { reminder.weekday },
                    set: { reminder.weekday = $0; onChange() }
                )) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }

                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .onChange(of: time) { _, newValue in
                        let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        reminder.hour = comps.hour ?? reminder.hour
                        reminder.minute = comps.minute ?? reminder.minute
                        onChange()
                    }
            }
        }
        .padding(.vertical, 2)
        .task {
            time = reminder.timeAsDate
        }
    }
}
