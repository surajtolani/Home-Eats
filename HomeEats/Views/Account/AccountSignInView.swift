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
    /// The name/profile step has no Skip/Cancel action at all, regardless
    /// of `allowsCancel` — unlike the old two-field name step, these five
    /// fields are genuinely mandatory now (see `RootView`'s completion
    /// gate), so a Skip button here would either do nothing useful (in the
    /// `allowsCancel: false` mandatory-gate context, `RootView`'s own
    /// completion gate would just show this exact same form again the
    /// instant it dismissed — see that view's doc comment) or leave a
    /// signed-in account walking around with an incomplete profile (in the
    /// dismissible-sheet context) for no reason. Neither is worth a button
    /// that exists only to bounce right back.
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

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .phone: phoneStep
                case .code: codeStep
                case .name: ProfileCompletionStepView(onSaved: { dismiss() })
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
                // No toolbar action at all on the name/profile step — see
                // `allowsCancel`'s own doc comment for why a Skip button
                // has no useful job here anymore now that all five fields
                // are mandatory. The phone/code steps are the actual "back
                // out of signing in" point, so those still honor
                // `allowsCancel` exactly as before.
                if step != .name, allowsCancel {
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
