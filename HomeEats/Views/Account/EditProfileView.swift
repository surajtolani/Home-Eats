import SwiftUI

/// Lets a signed-in user correct or fill in their five mandatory profile
/// fields (first name, last name, city, state, country) after the fact,
/// without having to sign out and back in. Reached from `SettingsView`'s
/// Account section.
///
/// Same partial-update contract as everywhere else this app talks to
/// `PATCH /me`: only the fields actually changed here are sent (see
/// `AccountsAPIClient.updateProfile`'s doc comment). That's still true even
/// though this screen no longer lets any of the five go blank (see
/// `canSave` below) — "only send what changed" and "don't allow saving a
/// blank value" are independent rules, not in tension: sending, say, only
/// `firstName` when that's the one field edited still leaves city/state/
/// country untouched server-side exactly as before, it just no longer lets
/// someone clear firstName itself down to nothing in the process.
struct EditProfileView: View {
    @EnvironmentObject private var accountSession: AccountSession
    @Environment(\.dismiss) private var dismiss

    @State private var firstNameInput = ""
    @State private var lastNameInput = ""
    @State private var cityInput = ""
    @State private var stateInput = ""
    @State private var countryInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// All five, non-empty — these used to be two independent checks
    /// (first/last name required, city/country freely blankable) back when
    /// city/country were genuinely optional. Now that every account needs
    /// all five (see `RootView`'s completion gate and
    /// `ProfileCompletionStepView`), this editor holds itself to the exact
    /// same bar: it must never be the screen that lets a once-complete
    /// profile become incomplete again by saving a blank value over an
    /// existing one.
    private var canSave: Bool {
        [firstNameInput, lastNameInput, cityInput, stateInput, countryInput].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("First name", text: $firstNameInput)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastNameInput)
                    .textContentType(.familyName)
            }
            Section {
                TextField("City", text: $cityInput)
                    .textContentType(.addressCity)
                TextField("State", text: $stateInput)
                    .textContentType(.addressState)
                TextField("Country", text: $countryInput)
                    .textContentType(.countryName)
            } footer: {
                // No longer "optional, not shown to anyone yet" — all five
                // fields on this screen are mandatory now (see `canSave`
                // above), same as the rest of this account's profile.
                Text("Shown to friends and group members when you share recipes or invite them.")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .disabled(isLoading)
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isLoading {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: loadCurrentValues)
    }

    /// Seeds the fields from whatever `AccountSession` already has cached
    /// (no separate `GET /me` needed — `currentUser` is kept fresh by every
    /// mutation that touches it, see `AccountSession.updateCurrentUser`).
    /// By the time this screen is reachable at all, every field should
    /// already be non-empty (`RootView`'s completion gate guarantees that
    /// for every signed-in account before it ever reaches the main tabs
    /// this screen is nested under) — falling back to `""` per field here
    /// is just defensive, not an expected case in practice.
    private func loadCurrentValues() {
        guard let user = accountSession.currentUser else { return }
        firstNameInput = user.firstName ?? ""
        lastNameInput = user.lastName ?? ""
        cityInput = user.city ?? ""
        stateInput = user.state ?? ""
        countryInput = user.country ?? ""
    }

    private func save() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let firstName = firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = cityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = stateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = countryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Every field is sent unconditionally here (never `nil` for an
            // empty one) — unlike the old city/country-optional version of
            // this screen, `canSave` above already guarantees none of the
            // five is blank by the time this runs, so there's no "leave
            // this one alone" case left to express for any of them.
            let updated = try await AccountsAPIClient.updateProfile(
                displayName: "\(firstName) \(lastName)",
                firstName: firstName,
                lastName: lastName,
                city: city,
                state: state,
                country: country
            )
            accountSession.updateCurrentUser(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
