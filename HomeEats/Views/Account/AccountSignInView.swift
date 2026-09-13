import SwiftUI

/// Phone-number sign-in, as a three-step sheet: phone entry -> SMS code
/// entry -> (only if the account is brand new) pick a display name.
/// Presented from wherever signing in is actually needed — `SettingsView`'s
/// "Sign In" row when someone opts in proactively, or `RecipeDetailView`'s
/// Share action when they tap Share while signed out (see that view's own
/// doc comment on why it prompts here first rather than failing silently).
///
/// Success is reflected entirely through `AccountSession`
/// (`@EnvironmentObject`) rather than a completion handler — a caller just
/// presents this as a `.sheet` and checks `accountSession.isSignedIn`
/// again once it's dismissed (see `RecipeDetailView`'s `onDismiss:` for an
/// example of picking back up right where the user left off).
struct AccountSignInView: View {
    @EnvironmentObject private var accountSession: AccountSession
    @Environment(\.dismiss) private var dismiss

    /// `true` everywhere this has always been used — presented as a
    /// dismissible `.sheet` from `SettingsView`'s "Sign In" row or
    /// `RecipeDetailView`'s Share action, where backing out just means "not
    /// signing in right now," not losing access to anything already open.
    ///
    /// `RootView` sets this `false` for the one place sign-in is *not*
    /// optional: the mandatory gate shown in place of the whole app before
    /// `accountSession.isSignedIn`. There, this view is embedded directly
    /// (not presented as a sheet) with nothing behind it to "cancel" back
    /// to — so the phone/code steps hide the Cancel button entirely. The
    /// name step keeps "Skip" either way once sign-in has actually
    /// succeeded (`verify()` already called `completeSignIn`), since
    /// skipping a display name doesn't undo being signed in — `dismiss()`
    /// is a harmless no-op here with no sheet to dismiss; `RootView`'s own
    /// `if !accountSession.isSignedIn` check is what actually swaps this
    /// view out once sign-in completes.
    var allowsCancel: Bool = true

    private enum Step {
        case phone, code, name
    }

    @State private var step: Step = .phone
    @State private var selectedCountry: CountryCode = .default
    @State private var showCountryPicker = false
    /// Just the local digits someone types — the country's dial code
    /// (`selectedCountry.dialCode`) is prepended separately when actually
    /// sending, not typed inline. Keeps the text field itself simple (a
    /// plain number pad, nothing to parse a leading "+" or country code out
    /// of) now that the picker is what decides the country instead of
    /// `PhoneNumberFormatting.e164`'s old "guess US if it's 10 digits"
    /// fallback.
    @State private var phoneInput = ""
    @State private var codeInput = ""
    @State private var firstNameInput = ""
    @State private var lastNameInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The phone number actually sent to the backend, normalized to E.164 —
    /// kept separate from `phoneInput` (what's literally in the text field)
    /// so "Use a Different Number" can hand the field back to the user
    /// without this view forgetting what the code was sent to in the
    /// meantime.
    @State private var confirmedPhoneNumber: String?

    /// Combines the picked country's dial code with whatever digits are
    /// typed — routed through `PhoneNumberFormatting.e164` regardless (it
    /// takes a leading-"+" string as-is, just re-validating its shape)
    /// rather than duplicating that regex here.
    private var enteredE164: String? {
        PhoneNumberFormatting.e164(from: selectedCountry.dialCode + phoneInput.filter(\.isNumber))
    }
    private var canSendCode: Bool {
        enteredE164 != nil
    }
    /// Twilio Verify codes run 4-10 digits depending on channel/config (see
    /// the same loose lower bound backend/routes/auth.js's `VerifySchema`
    /// uses) — this just gates the button, Twilio's own check is what
    /// actually matters.
    private var canVerify: Bool {
        codeInput.trimmingCharacters(in: .whitespaces).count >= 4
    }
    private var canSaveName: Bool {
        !firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .phone: phoneStep
                case .code: codeStep
                case .name: nameStep
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The name step is the one point where dismissing isn't
                // really "cancel" — sign-in already succeeded by then (see
                // `verify()`), so leaving without a name is just skipping an
                // optional step, not backing out of signing in at all —
                // "Skip" stays available here even when `allowsCancel` is
                // false. The phone/code steps are the actual "back out of
                // signing in" point, so those honor `allowsCancel`.
                if step == .name {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") { dismiss() }
                    }
                } else if allowsCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var title: String {
        switch step {
        case .phone: return "Sign In"
        case .code: return "Enter Code"
        case .name: return "Your Name"
        }
    }

    private var phoneStep: some View {
        Group {
            // Only on the phone step, not code/name — this is specifically
            // the "front door" moment (especially for `RootView`'s
            // mandatory, allowsCancel: false gate, where this is the very
            // first thing anyone sees before the rest of the app exists to
            // them at all); repeating it on every step would just be noise
            // once someone's already mid-flow. Same `BrandWordmark` artwork
            // `BrandHeaderBanner` uses everywhere else, just larger — this
            // is the one screen in the app that's allowed to actually be a
            // "landing page" rather than a nav bar title.
            Section {
                HStack {
                    Spacer()
                    Image("BrandWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                    Spacer()
                }
                .padding(.vertical, 20)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                HStack(spacing: 0) {
                    Button {
                        showCountryPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedCountry.flag)
                            Text(selectedCountry.dialCode)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)

                    Divider().frame(height: 20)

                    TextField("Phone number", text: $phoneInput)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)
                        .padding(.leading, 10)
                }
            } footer: {
                Text("We'll text you a one-time code — no password to remember.")
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
                        Task { await sendCode() }
                    } label: {
                        Text("Send Code")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .disabled(!canSendCode)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(selected: $selectedCountry)
        }
    }

    private var codeStep: some View {
        Group {
            Section {
                if let confirmedPhoneNumber {
                    Text("Sent to \(confirmedPhoneNumber).").foregroundStyle(.secondary)
                }
                TextField("Code", text: $codeInput)
                    .keyboardType(.numberPad)
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
                        Task { await verify() }
                    } label: {
                        Text("Verify")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .disabled(!canVerify)

                    Button("Use a Different Number") {
                        step = .phone
                        codeInput = ""
                        errorMessage = nil
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var nameStep: some View {
        Group {
            Section {
                TextField("First name", text: $firstNameInput)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastNameInput)
                    .textContentType(.familyName)
            } footer: {
                Text("Shown to friends and group members when you share recipes or invite them. You can add your city and country later from Settings.")
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
                        Task { await saveName() }
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .disabled(!canSaveName)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func sendCode() async {
        guard let e164 = enteredE164 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AccountsAPIClient.requestCode(phoneNumber: e164)
            confirmedPhoneNumber = e164
            step = .code
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verify() async {
        guard let phoneNumber = confirmedPhoneNumber else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (token, user) = try await AccountsAPIClient.verifyCode(
                phoneNumber: phoneNumber,
                code: codeInput.trimmingCharacters(in: .whitespaces)
            )
            accountSession.completeSignIn(token: token, user: user)
            if user.fullName != nil {
                dismiss()
            } else {
                // Brand new (or never-named) account — ask once before
                // dismissing, since a name is how this person will show up
                // to friends/groups once they start sharing.
                step = .name
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveName() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let firstName = firstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = lastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // `displayName` is set alongside `firstName`/`lastName` here
            // (rather than being asked for as its own separate field) so
            // every existing "shown to friends" reader
            // (`displayNameOrPhoneNumber`) keeps working unchanged — see
            // `AccountUser.fullName`'s doc comment.
            let updated = try await AccountsAPIClient.updateProfile(
                displayName: "\(firstName) \(lastName)",
                firstName: firstName,
                lastName: lastName
            )
            accountSession.updateCurrentUser(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// `CountryPickerSheet` used to live here as a `private struct` — it's now
// its own file (`HomeEats/Views/Shared/CountryPickerSheet.swift`, internal
// rather than private) so `ContactOrPhoneNumberPickerView`'s manual
// phone-entry path can reuse the exact same picker. See that file's doc
// comment for the full reasoning.
