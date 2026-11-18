import SwiftUI

/// Phone-number sign-in, as a three-step sheet: phone entry -> SMS code
/// entry -> (only if the account's profile isn't already complete) fill in
/// first/last name, city, state, and country — see `ProfileCompletionStepView`
/// for that step's actual fields; every account needs all five before it can
/// be used at all (see `RootView`'s own completion gate, which is what
/// actually enforces that for a signed-in-but-incomplete account reopening
/// the app later — this view's own `.name` step just gets the common case,
/// filling it in once right after verifying, out of the way immediately).
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
    /// to — so the phone/code steps hide the Cancel button entirely.
    ///
    /// Cancel only ever appears on the phone step. The code and profile
    /// steps have a Back button instead, whatever `allowsCancel` says: Back
    /// from the code step returns to the phone step, and Back from the
    /// profile step signs out of the account that was just verified and
    /// returns to the phone step, so a mistyped number never forces anyone
    /// to fill in a profile. There is still no Skip on the profile step:
    /// all five fields are mandatory (see `RootView`'s completion gate).
    var allowsCancel: Bool = true

    private enum Step {
        case phone, code, name
    }

    @State private var step: Step = .phone
    @State private var selectedCountry: CountryCode = .default
    @State private var showCountryPicker = false
    /// What's in the phone field: normally the national number, with the
    /// country coming from the picker. When autofill or a paste puts a full
    /// international number here ("+1 (781) 363-3306"), the `.onChange`
    /// on the field moves its country code into the picker and leaves only
    /// the national part. If the code isn't one the picker lists, the "+"
    /// number stays here and is used as is.
    @State private var phoneInput = ""
    @State private var codeInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The phone number actually sent to the backend, normalized to E.164 —
    /// kept separate from `phoneInput` (what's literally in the text field)
    /// so "Use a Different Number" can hand the field back to the user
    /// without this view forgetting what the code was sent to in the
    /// meantime.
    @State private var confirmedPhoneNumber: String?

    /// The field's number in E.164 form, using the picked country unless
    /// the field already has its own "+" country code. It used to always put
    /// the picker's code in front of the field's digits, so an autofilled
    /// "+1 (781) 363-3306" became "+117813633306".
    private var enteredE164: String? {
        PhoneNumberFormatting.e164(from: phoneInput, defaultCountry: selectedCountry)
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

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .phone: phoneStep
                case .code: codeStep
                case .name:
                    ProfileCompletionStepView(
                        onSaved: { dismiss() },
                        onUseDifferentNumber: signOutAndUseDifferentNumber
                    )
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
                // See `allowsCancel`'s doc comment.
                if step == .phone, allowsCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
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
        }
    }

    private var title: String {
        switch step {
        case .phone: return "Sign In"
        case .code: return "Enter Code"
        case .name: return "Complete Your Profile"
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
                        // Phone pad rather than number pad so a "+" can be
                        // typed for a country the picker doesn't list.
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
                    .textContentType(.oneTimeCode)
            } footer: {
                Text("Wrong number? Tap Back or Use a Different Number to fix it.")
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

                    Button("Use a Different Number", action: useDifferentNumber)
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func sendCode() async {
        // Real, confirmed bug: the "Send Code" `Button` swaps for a
        // `ProgressView` once `isLoading` is `true` (see `body` above), but
        // that's a SwiftUI *render* reacting to state, not something that
        // can block a tap that already happened — each tap spawns its own
        // independent `Task { await sendCode() }`, and without a guard here,
        // any of those that land before the view actually re-renders (a
        // laggy/janky moment — exactly what a crash-and-relaunch cycle
        // produces) each independently proceeds to call
        // `AccountsAPIClient.requestCode(phoneNumber:)`, firing a second (or
        // third) real Twilio SMS for what was, from the user's side, "one"
        // attempt at signing in. `guard !isLoading` makes a re-entrant call
        // an outright no-op instead of a second real send.
        guard !isLoading, let e164 = enteredE164 else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // The server answers with the number in its canonical form
            // (backend/lib/phone.js), which is what the code was really sent
            // to, so that's what "Sent to" shows and verify-code sends. An
            // older server doesn't include it.
            let canonical = try await AccountsAPIClient.requestCode(phoneNumber: e164)
            confirmedPhoneNumber = canonical ?? e164
            step = .code
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Code step -> phone step, keeping what's in the phone field so a typo
    /// can be fixed rather than retyped.
    private func useDifferentNumber() {
        step = .phone
        codeInput = ""
        errorMessage = nil
    }

    /// Profile step -> phone step. The number has already been verified and
    /// signed in by this point, so this signs out of that account first.
    /// The account itself stays on the server, with no profile.
    private func signOutAndUseDifferentNumber() {
        accountSession.signOut()
        confirmedPhoneNumber = nil
        useDifferentNumber()
    }

    private func verify() async {
        // Same re-entrancy guard, same reasoning, as `sendCode()` above —
        // `POST /auth/verify-code` only ever accepts one code per attempt
        // anyway, but there's no reason to send a stray duplicate request.
        guard !isLoading, let phoneNumber = confirmedPhoneNumber else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (token, user) = try await AccountsAPIClient.verifyCode(
                phoneNumber: phoneNumber,
                code: codeInput.trimmingCharacters(in: .whitespaces)
            )
            accountSession.completeSignIn(token: token, user: user)
            // `profileComplete` (the backend's own derived check — see
            // routes/me.js's `computeProfileComplete`) is what decides
            // whether this account still needs the profile step, not just
            // "does it have a name": a returning account that already has a
            // first/last name but signed up before city/state/country
            // became mandatory would have passed the old `fullName != nil`
            // check here and skipped straight past collecting the other
            // three — exactly the gap this task closes. (In practice, for
            // the mandatory `RootView`-embedded sign-in — `allowsCancel:
            // false` — `RootView`'s own completion gate would catch that
            // gap a moment later anyway; checking `profileComplete` here
            // too just means this view's own flow gets it right immediately
            // instead of relying on that second layer.)
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
