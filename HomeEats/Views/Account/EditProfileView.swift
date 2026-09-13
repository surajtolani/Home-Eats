import SwiftUI

/// Lets a signed-in user fill in or change the profile fields that
/// `AccountSignInView`'s post-sign-up name step doesn't ask for — city and
/// country — and, separately, correct their first/last name later without
/// having to sign out and back in. Reached from `SettingsView`'s Account
/// section.
///
/// Same partial-update contract as everywhere else this app talks to
/// `PATCH /me`: only the fields actually changed here are sent (see
/// `AccountsAPIClient.updateProfile`'s doc comment) — leaving, say, city
/// blank when a first/last name edit is all that changed does not clear it
/// server-side, it just isn't included in the request at all.
struct EditProfileView: View {
    @EnvironmentObject private var accountSession: AccountSession
    @Environment(\.dismiss) private var dismiss

    @State private var firstNameInput = ""
    @State private var lastNameInput = ""
    @State private var cityInput = ""
    @State private var countryInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                TextField("Country", text: $countryInput)
                    .textContentType(.countryName)
            } footer: {
                Text("Optional — not shown to friends or groups yet, just kept with your account.")
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
    /// City/country are optional server-side and simply blank when unset.
    private func loadCurrentValues() {
        guard let user = accountSession.currentUser else { return }
        firstNameInput = user.firstName ?? ""
        lastNameInput = user.lastName ?? ""
        cityInput = user.city ?? ""
        countryInput = user.country ?? ""
    }

    private func save() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let firstName = firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = cityInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = countryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // City/country are sent only when non-empty — an emptied field
            // here just means "don't change it," matching this route's
            // documented "no clear-to-null" contract (see routes/me.js's
            // doc comment): there is no way to blank out a city once set
            // from this screen, only to overwrite it with a different one.
            let updated = try await AccountsAPIClient.updateProfile(
                displayName: "\(firstName) \(lastName)",
                firstName: firstName,
                lastName: lastName,
                city: city.isEmpty ? nil : city,
                country: country.isEmpty ? nil : country
            )
            accountSession.updateCurrentUser(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
