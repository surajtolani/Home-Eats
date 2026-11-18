import SwiftUI

/// The app's front door, with Sign In and Create Account kept apart:
///
/// - **Sign In**: phone number -> SMS code. A code is only texted to a
///   number that already has an account; any other number gets "We couldn't
///   sign you in with this number. New here? Tap Create Account." from the
///   server, and nothing is sent or created.
/// - **Create Account** (the button under Sign In): phone number, first and
///   last name, and email -> SMS code -> city, state and country. A number
///   that already has an account is told to sign in instead. The account is
///   created, with the name and email, only once the code is verified. City
///   comes after the code because the city lookup is only available to
///   signed-in users (it's billed per use).
///
/// After verifying, an account whose profile isn't complete (every Create
/// Account, and older accounts that never finished) goes to the `.name`
/// step, `ProfileCompletionStepView`, with what's known already filled in.
/// `RootView` enforces the same thing for an incomplete account reopening
/// the app later.
///
/// Embedded by `RootView` as the mandatory gate (`allowsCancel: false`), or
/// presented as a sheet where signing in is optional. Success is reflected
/// entirely through `AccountSession` (`@EnvironmentObject`) rather than a
/// completion handler.
struct AccountSignInView: View {
    @EnvironmentObject private var accountSession: AccountSession
    @Environment(\.dismiss) private var dismiss

    /// `false` only for `RootView`'s mandatory gate, where there's nothing
    /// behind this screen to cancel back to. Cancel only ever appears on
    /// the Sign In screen itself. Every later screen has a Back button
    /// instead, whatever this says:
    /// - Create Account -> Sign In.
    /// - Code -> the screen the code was requested from, with what was
    ///   typed kept, so a wrong number can be fixed.
    /// - Profile -> signs out of the account that was just verified and
    ///   returns to Sign In.
    /// There is no Skip on the profile step: all five fields are mandatory.
    var allowsCancel: Bool = true

    private enum Step {
        case phone, code, name
    }

    private enum Mode {
        case signIn, createAccount
    }

    @State private var step: Step = .phone
    @State private var mode: Mode = .signIn
    @State private var selectedCountry: CountryCode = .default
    @State private var showCountryPicker = false
    /// What's in the phone field: normally the national number, with the
    /// country coming from the picker. When autofill or a paste puts a full
    /// international number here ("+1 (781) 363-3306"), the `.onChange`
    /// on the field moves its country code into the picker and leaves only
    /// the national part. If the code isn't one the picker lists, the "+"
    /// number stays here and is used as is.
    @State private var phoneInput = ""
    @State private var firstNameInput = ""
    @State private var lastNameInput = ""
    @State private var emailInput = ""
    @State private var codeInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The phone number the code was actually sent to, in the server's
    /// canonical form. Kept separate from `phoneInput` (what's in the text
    /// field) so going back to fix the number doesn't lose track of where
    /// the pending code went.
    @State private var confirmedPhoneNumber: String?

    /// The field's number in E.164 form, using the picked country unless
    /// the field already has its own "+" country code. It used to always put
    /// the picker's code in front of the field's digits, so an autofilled
    /// "+1 (781) 363-3306" became "+117813633306".
    private var enteredE164: String? {
        PhoneNumberFormatting.e164(from: phoneInput, defaultCountry: selectedCountry)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A quick shape check that gates the button: something before an "@"
    /// and a dot in the part after it, no spaces. The server checks the
    /// address properly and answers with a clear message if it's wrong.
    private var emailLooksValid: Bool {
        let email = trimmed(emailInput)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(" ") else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex
    }

    private var canSendCode: Bool {
        guard enteredE164 != nil else { return false }
        switch mode {
        case .signIn:
            return true
        case .createAccount:
            return !trimmed(firstNameInput).isEmpty && !trimmed(lastNameInput).isEmpty && emailLooksValid
        }
    }

    /// Twilio Verify codes run 4-10 digits depending on channel/config (see
    /// the same loose lower bound backend/routes/auth.js's `VerifySchema`
    /// uses) — this just gates the button, Twilio's own check is what
    /// actually matters.
    private var canVerify: Bool {
        codeInput.trimmingCharacters(in: .whitespaces).count >= 4
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .phone:
                    if mode == .signIn {
                        signInStep
                    } else {
                        createAccountStep
                    }
                case .code:
                    codeStep
                case .name:
                    ProfileCompletionStepView(
                        onSaved: { dismiss() },
                        onUseDifferentNumber: signOutAndUseDifferentNumber
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // See `allowsCancel`'s doc comment.
                if step == .phone, mode == .signIn, allowsCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                if step == .phone, mode == .createAccount {
                    ToolbarItem(placement: .cancellationAction) {
                        BackToolbarButton(action: backToSignIn)
                            .disabled(isLoading)
                    }
                }
                if step == .code {
                    ToolbarItem(placement: .cancellationAction) {
                        BackToolbarButton(action: useDifferentNumber)
                            .disabled(isLoading)
                    }
                }
                if step == .name {
                    ToolbarItem(placement: .cancellationAction) {
                        BackToolbarButton(action: signOutAndUseDifferentNumber)
                            .disabled(accountSession.isSigningOut)
                    }
                }
            }
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerSheet(selected: $selectedCountry)
            }
        }
    }

    private var title: String {
        switch step {
        case .phone: return mode == .signIn ? "Sign In" : "Create Account"
        case .code: return "Enter Code"
        case .name: return "Complete Your Profile"
        }
    }

    // MARK: - Steps

    private var signInStep: some View {
        Group {
            // The front door: the one screen allowed to be a landing page
            // rather than a nav bar title. Same `BrandWordmark` artwork as
            // `BrandHeaderBanner`, larger.
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
                phoneNumberRow
            } header: {
                Text("Sign in with your phone number")
            } footer: {
                Text("We'll text you a one-time code — no password to remember.")
            }
            .disabled(isLoading)

            errorSection

            sendCodeSection

            Section {
                Button("Create Account", action: showCreateAccount)
                    .frame(maxWidth: .infinity)
                    .disabled(isLoading)
            } header: {
                Text("New to Home Eats?")
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var createAccountStep: some View {
        Group {
            Section {
                phoneNumberRow
            } header: {
                Text("Phone number")
            } footer: {
                Text("We'll text a code to this number to confirm it's yours.")
            }

            Section {
                TextField("First name", text: $firstNameInput)
                    .textContentType(.givenName)
                TextField("Last name", text: $lastNameInput)
                    .textContentType(.familyName)
                TextField("Email", text: $emailInput)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("About you")
            } footer: {
                Text("After the code, you'll pick your city. Your name is shown to friends and group members; your email isn't shown to anyone.")
            }

            errorSection

            sendCodeSection
        }
        .disabled(isLoading)
    }

    private var codeStep: some View {
        Group {
            Section {
                if let confirmedPhoneNumber {
                    Text("Sent to \(confirmedPhoneNumber).").foregroundStyle(.secondary)
                }
                TextField("Code", text: $codeInput)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
            } footer: {
                Text("Wrong number? Tap Back or Use a Different Number to fix it.")
            }
            .disabled(isLoading)

            errorSection

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
                        Text(mode == .signIn ? "Verify" : "Verify and Continue")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandForest)
                    .controlSize(.large)
                    .disabled(!canVerify)

                    Button("Use a Different Number", action: useDifferentNumber)
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Pieces shared by the steps

    private var phoneNumberRow: some View {
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
                // Phone pad rather than number pad so a "+" can be typed
                // for a country the picker doesn't list.
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding(.leading, 10)
                .onChange(of: phoneInput) { _, newValue in
                    if let split = PhoneNumberFormatting.splitInternational(newValue, current: selectedCountry) {
                        selectedCountry = split.country
                        phoneInput = split.nationalDigits
                    }
                }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
    }

    private var sendCodeSection: some View {
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

    // MARK: - Navigation

    /// Sign In -> Create Account. The phone number already typed is kept.
    private func showCreateAccount() {
        mode = .createAccount
        errorMessage = nil
    }

    /// Create Account -> Sign In. The phone number is kept; the rest of
    /// the form is kept too, in case they come back.
    private func backToSignIn() {
        mode = .signIn
        errorMessage = nil
    }

    /// Code step -> the screen the code was requested from, keeping what's
    /// in its fields so a typo can be fixed rather than retyped.
    private func useDifferentNumber() {
        step = .phone
        codeInput = ""
        errorMessage = nil
    }

    /// Profile step -> Sign In. The number has already been verified and
    /// signed in by this point, so this signs out of that account first.
    /// The account itself stays on the server, without a complete profile;
    /// Create Account with the same number finishes it later.
    private func signOutAndUseDifferentNumber() {
        accountSession.signOut()
        confirmedPhoneNumber = nil
        mode = .signIn
        useDifferentNumber()
    }

    // MARK: - Network

    private func sendCode() async {
        // Each tap spawns its own `Task`, and taps that land before the
        // view re-renders with the spinner (a laggy moment, such as right
        // after a relaunch) would each send a real, billed SMS. This guard
        // makes a re-entrant call a no-op.
        guard !isLoading, canSendCode, let e164 = enteredE164 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // The server answers with the number in its canonical form
            // (backend/lib/phone.js), which is what the code was really sent
            // to, so that's what "Sent to" shows and verify-code sends. An
            // older server doesn't include it.
            let canonical = try await AccountsAPIClient.requestCode(
                phoneNumber: e164,
                intent: mode == .signIn ? .signIn : .signUp
            )
            confirmedPhoneNumber = canonical ?? e164
            step = .code
        } catch {
            // Includes the server's "no account with this number, tap
            // Create Account" and "already has an account, sign in" answers.
            errorMessage = error.localizedDescription
        }
    }

    private func verify() async {
        // Same re-entrancy guard, same reasoning, as `sendCode()` above.
        guard !isLoading, let phoneNumber = confirmedPhoneNumber else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let profile: SignupProfile? = mode == .createAccount
                ? SignupProfile(
                    firstName: trimmed(firstNameInput),
                    lastName: trimmed(lastNameInput),
                    email: trimmed(emailInput)
                )
                : nil
            let (token, user) = try await AccountsAPIClient.verifyCode(
                phoneNumber: phoneNumber,
                code: codeInput.trimmingCharacters(in: .whitespaces),
                intent: mode == .signIn ? .signIn : .signUp,
                profile: profile
            )
            accountSession.completeSignIn(token: token, user: user)
            // `profileComplete` is the server's own check of all five
            // fields. In `RootView`'s mandatory gate, `RootView` swaps to
            // its own profile screen as soon as the session is signed in;
            // this covers the sheet case.
            if user.profileComplete {
                dismiss()
            } else {
                step = .name
            }
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

/// A toolbar "< Back" button: the chevron and the word, like the system's
/// own back button, for screens that aren't pushed on a navigation stack and
/// so don't get one.
struct BackToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
                Text("Back")
            }
        }
        .accessibilityLabel("Back")
    }
}
