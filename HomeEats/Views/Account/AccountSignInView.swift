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

    private enum Step {
        case phone, code, name
    }

    @State private var step: Step = .phone
    @State private var phoneInput = ""
    @State private var codeInput = ""
    @State private var nameInput = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The phone number actually sent to the backend, normalized to E.164 —
    /// kept separate from `phoneInput` (what's literally in the text field)
    /// so "Use a Different Number" can hand the field back to the user
    /// without this view forgetting what the code was sent to in the
    /// meantime.
    @State private var confirmedPhoneNumber: String?

    private var canSendCode: Bool {
        PhoneNumberFormatting.e164(from: phoneInput) != nil
    }
    /// Twilio Verify codes run 4-10 digits depending on channel/config (see
    /// the same loose lower bound backend/routes/auth.js's `VerifySchema`
    /// uses) — this just gates the button, Twilio's own check is what
    /// actually matters.
    private var canVerify: Bool {
        codeInput.trimmingCharacters(in: .whitespaces).count >= 4
    }
    private var canSaveName: Bool {
        !nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                ToolbarItem(placement: .cancellationAction) {
                    // The name step is the one point where dismissing isn't
                    // really "cancel" — sign-in already succeeded by then
                    // (see `verify()`), so leaving without a name is just
                    // skipping an optional step, not backing out of signing
                    // in at all.
                    Button(step == .name ? "Skip" : "Cancel") { dismiss() }
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
            Section {
                TextField("Phone number", text: $phoneInput)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            } footer: {
                Text("We'll text you a one-time code — no password to remember.")
            }
            .disabled(isLoading)

            Section {
                if isLoading {
                    ProgressView()
                } else {
                    Button("Send Code") { Task { await sendCode() } }
                        .disabled(!canSendCode)
                }
            }
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
                    ProgressView()
                } else {
                    Button("Verify") { Task { await verify() } }
                        .disabled(!canVerify)
                    Button("Use a Different Number") {
                        step = .phone
                        codeInput = ""
                        errorMessage = nil
                    }
                }
            }
        }
    }

    private var nameStep: some View {
        Group {
            Section {
                TextField("Display name", text: $nameInput)
                    .textContentType(.name)
            } footer: {
                Text("Shown to friends and group members when you share recipes with them.")
            }
            .disabled(isLoading)

            Section {
                if isLoading {
                    ProgressView()
                } else {
                    Button("Save") { Task { await saveName() } }
                        .disabled(!canSaveName)
                }
            }
        }
    }

    private func sendCode() async {
        guard let e164 = PhoneNumberFormatting.e164(from: phoneInput) else { return }
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
            if let displayName = user.displayName, !displayName.isEmpty {
                dismiss()
            } else {
                // Brand new (or never-named) account — ask once before
                // dismissing, since a display name is how this person will
                // show up to friends/groups once they start sharing.
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
        do {
            let updated = try await AccountsAPIClient.updateDisplayName(
                nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            accountSession.updateCurrentUser(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
