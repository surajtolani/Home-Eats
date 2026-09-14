import SwiftUI

/// The "fill in your mandatory profile" form content — first name, last
/// name, city, state, and country — shared by the two places this app now
/// needs the exact same five fields, collected the exact same way:
///
/// 1. `AccountSignInView`'s post-verification step, for a brand-new account
///    (or one that verified before but never finished this step).
/// 2. `RootView`'s own gate, for a *returning*, already-signed-in account
///    whose profile was never completed — every account that existed
///    before these five fields became mandatory, including this session's
///    own earlier test accounts (see `RootView`'s doc comment on exactly
///    where that gate sits in its chain, and why).
///
/// Deliberately just the `Section`s that go inside SOMEONE ELSE's
/// `Form`/`NavigationStack` — not a fully standalone screen with its own
/// navigation chrome — because the two call sites need different chrome
/// around it: `AccountSignInView` already has one shared `Form` and a
/// toolbar that switches between "Cancel" (phone/code steps) and "Skip"...
/// except this step is no longer skippable (see below), while `RootView`'s
/// gate is a full-screen replacement with no toolbar at all, the same way
/// `AccountSignInView(allowsCancel: false)` itself already works one gate
/// up. Extracting only the shared fields+button — not a whole screen —
/// avoids two independently-drifting copies of the same five `TextField`s
/// while still letting each call site own its own surrounding structure.
///
/// Uses `Section { } header: { } footer: { }` throughout (never
/// `Section("title") { } footer: { }`, which isn't valid SwiftUI) — see
/// this codebase's own established convention on that exact point.
struct ProfileCompletionStepView: View {
    @EnvironmentObject private var accountSession: AccountSession

    /// Called after a successful save, once `accountSession.currentUser`
    /// has already been updated with the fresh, now-complete profile (this
    /// view calls `accountSession.updateCurrentUser` itself before invoking
    /// this). `AccountSignInView` uses it purely to `dismiss()` its sheet.
    /// `RootView`'s gate passes nothing at all: it needs no extra action —
    /// `currentUser.profileComplete` flipping to `true` is itself what
    /// makes `RootView`'s own gating `if/else if` chain swap this view out
    /// for whatever comes next, through the same `@Published`/
    /// `@EnvironmentObject` reactivity every other transition in that chain
    /// already relies on (see `RootView`'s doc comment).
    var onSaved: (() -> Void)?

    @State private var firstNameInput = ""
    @State private var lastNameInput = ""
    @State private var cityInput = ""
    @State private var stateInput = ""
    @State private var countryInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// All five, non-empty — matching the backend's own
    /// `computeProfileComplete` exactly (see routes/me.js), so a click of
    /// "Save" here can never come back a `400` for a field this button
    /// itself should already have refused to enable on.
    private var canSave: Bool {
        [firstNameInput, lastNameInput, cityInput, stateInput, countryInput].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Group {
            Section {
                TextField("First name", text: $firstNameInput)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastNameInput)
                    .textContentType(.familyName)
                TextField("City", text: $cityInput)
                    .textContentType(.addressCity)
                // State/Country are `Picker`s from a predetermined list, not
                // free text — direct user request. `Text("Select a
                // state"/"Select a country").tag("")` is a real, selectable
                // placeholder row (not a disabled prompt) specifically so an
                // untouched field stays genuinely empty — `canSave` below
                // needs a real "nothing chosen yet" state, and a `Picker`
                // with no explicit placeholder row would otherwise default
                // to silently pre-selecting its first real option, which
                // would let someone "complete" their profile with a
                // state/country they never actually picked.
                Picker("State", selection: $stateInput) {
                    Text("Select a state").tag("")
                    ForEach(USState.all, id: \.self) { state in
                        Text(state).tag(state)
                    }
                }
                Picker("Country", selection: $countryInput) {
                    Text("Select a country").tag("")
                    ForEach(CountryCode.all) { country in
                        Text(country.name).tag(country.name)
                    }
                }
            } header: {
                Text("Your Profile")
            } footer: {
                // No more "you can add this later from Settings" framing —
                // that used to be true only for city/country, and is no
                // longer true for any of these five: every account needs
                // all five to use Home Eats, full stop.
                Text("Shown to friends and group members when you share recipes or invite them. Every account needs a first name, last name, city, state, and country — there's no adding these later.")
            }
            .disabled(isLoading)

            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    Button {
                        Task { await save() }
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .disabled(!canSave)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .onAppear(perform: loadCurrentValues)
    }

    /// Pre-fills from whatever `AccountSession` already has cached. This
    /// matters most for `RootView`'s gate: a returning account might
    /// already have SOME of the five set (e.g. an account that signed up
    /// before this change, with a name but no city/state/country) and
    /// shouldn't have to retype what's already on file just to finish the
    /// rest. `AccountSignInView`'s call site gets the same behavior for
    /// free, which is also correct there — a brand-new account has nothing
    /// cached to pre-fill, but one that verified once and dismissed this
    /// step without saving (back when it was still skippable) might.
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
            // `displayName` is set alongside the name fields here (rather
            // than being asked for as its own separate field) so every
            // existing "shown to friends" reader (`displayNameOrPhoneNumber`)
            // keeps working unchanged — see `AccountUser.fullName`'s doc
            // comment. All five fields are sent together every time this
            // saves (not just whichever changed) — unlike `EditProfileView`,
            // this step's whole job is getting a still-incomplete profile to
            // `profileComplete: true` in one shot, and `canSave` above
            // already guarantees none of the five is blank by the time this
            // runs.
            let updated = try await AccountsAPIClient.updateProfile(
                displayName: "\(firstName) \(lastName)",
                firstName: firstName,
                lastName: lastName,
                city: city,
                state: state,
                country: country
            )
            accountSession.updateCurrentUser(updated)
            onSaved?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
