import SwiftUI
import UIKit

/// One completed pick from `ContactOrPhoneNumberPickerView`, handed back
/// through `onPick` — a phone number already normalized to E.164 (so every
/// caller can pass it straight to `AccountsAPIClient.inviteToGroup(groupID:
/// phoneNumber:)` without re-validating it) plus a label to show the person
/// who picked it (a contact's name, or just the number itself when it was
/// typed manually rather than chosen from Contacts).
struct PickedPhoneContact: Hashable {
    let displayLabel: String
    let phoneNumber: String
}

/// "Who do you want to add?" — search device Contacts by name, or type a
/// phone number directly, and hand back a single normalized pick. Built as
/// one shared sheet specifically so it can be reused, unmodified, across
/// every place this app adds someone by phone number: `CreateGroupView`'s
/// member step (the group doesn't exist yet, so its caller queues the pick
/// locally rather than inviting immediately), `GroupDetailView`'s
/// `InviteToGroupView` (the group already exists, so its caller invites
/// right away), and `FriendsListView`'s "Add Friend" flow (no group
/// involved at all — its caller sends a plain friend request). None of
/// those callers are told *how* a `PickedPhoneContact` was produced — from a
/// tapped contact or a typed number — since they all converge on the same
/// shape and each just does its own thing with the resulting phone number
/// (`AccountsAPIClient.inviteToGroup(groupID:phoneNumber:)` for the first
/// two, which already creates a friend request alongside the group invite
/// for a phone number that isn't yet an accepted friend — see that method's
/// own doc comment — or a plain `sendFriendRequest(phoneNumber:)` for the
/// third).
///
/// This intentionally does NOT also offer "from your accepted friends" —
/// `CreateGroupView.friendToggleRow` and `InviteToGroupView`'s "From Your
/// Friends" section already cover that, unaffected by this file; this sheet
/// is specifically the *other* path, for anyone who isn't an accepted
/// friend yet (in Contacts or not).
struct ContactOrPhoneNumberPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contactsService = ContactsSearchService()
    @State private var searchText = ""
    /// Set when a tapped contact has more than one phone number on file —
    /// drives the `.confirmationDialog` below asking which one to use.
    /// `nil` the rest of the time, including right after a number is
    /// actually chosen from it.
    @State private var contactNumberChoice: DeviceContact?

    // Manual entry, mirroring `AccountSignInView`'s own phone step exactly
    // (same `CountryCode`/`CountryPickerSheet`/`PhoneNumberFormatting`) so
    // typing a number here behaves identically to typing one at sign-in,
    // not a second, differently-behaved phone field.
    @State private var selectedCountry: CountryCode = .default
    @State private var manualDigits = ""
    @State private var showCountryPicker = false

    /// Set when a contact's own stored number doesn't normalize to a valid
    /// E.164 shape (an extension, a landline written unusually, ...) — the
    /// one pick path that can silently fail otherwise, since tapping a
    /// contact row has no separate "disabled until valid" gate the way the
    /// manual-entry button does. Shown inline rather than left silent, per
    /// this app's own "no permission/edge case should look like a dead
    /// button" bar (see `ContactsSearchService.loadIfNeeded`'s doc comment).
    @State private var pickErrorMessage: String?

    /// Called once, with the final pick, immediately before this view
    /// dismisses itself — same "hand back a value and close" convention as
    /// `RecipePickerSheet`/`RestaurantPickerSheet`. Not called at all if the
    /// sheet is cancelled.
    let onPick: (PickedPhoneContact) -> Void

    private var filteredContacts: [DeviceContact] {
        ContactSearch.filter(contactsService.contacts, matching: searchText)
    }

    private var manualE164: String? {
        PhoneNumberFormatting.e164(from: selectedCountry.dialCode + manualDigits.filter(\.isNumber))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    contactsSectionContent
                } header: {
                    Text("From Your Contacts")
                }

                Section {
                    HStack(spacing: 0) {
                        Button {
                            showCountryPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedCountry.flag)
                                Text(selectedCountry.dialCode).foregroundStyle(.primary)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 10)

                        Divider().frame(height: 20)

                        TextField("Phone number", text: $manualDigits)
                            .keyboardType(.numberPad)
                            .textContentType(.telephoneNumber)
                            .padding(.leading, 10)
                    }
                    Button("Add") {
                        guard let e164 = manualE164 else { return }
                        finish(PickedPhoneContact(displayLabel: e164, phoneNumber: e164))
                    }
                    .disabled(manualE164 == nil)
                } header: {
                    Text("Or Enter a Phone Number")
                } footer: {
                    Text("Works for anyone, whether or not they're in your contacts or already on Home Eats.")
                }

                if let pickErrorMessage {
                    Section {
                        Text(pickErrorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Someone")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search contacts by name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await contactsService.loadIfNeeded() }
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerSheet(selected: $selectedCountry)
            }
            .confirmationDialog(
                contactNumberChoice?.name ?? "",
                isPresented: Binding(
                    get: { contactNumberChoice != nil },
                    set: { isPresented in if !isPresented { contactNumberChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let contact = contactNumberChoice {
                    ForEach(contact.phoneNumbers, id: \.self) { rawNumber in
                        Button(rawNumber) { pick(contact: contact, rawNumber: rawNumber) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contactsSectionContent: some View {
        switch contactsService.authorizationState {
        case .notRequested:
            if contactsService.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        case .denied:
            deniedContactsMessage
        case .authorized:
            if filteredContacts.isEmpty {
                Text(searchText.isEmpty
                     ? "No contacts with a phone number found."
                     : "No contacts match \"\(searchText)\".")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredContacts) { contact in
                    contactRow(contact)
                }
            }
        }
    }

    /// Same message-plus-"Open Settings" pattern as this app's other
    /// permission-gated features — not a silent empty list, which would
    /// otherwise look identical to "you have no contacts."
    private var deniedContactsMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Home Eats can't see your contacts.")
                .foregroundStyle(.primary)
            Text("Grant access in Settings to search by name — or just type a phone number below, which works either way.")
                .font(.brandCaption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func contactRow(_ contact: DeviceContact) -> some View {
        Button {
            pickErrorMessage = nil
            if contact.phoneNumbers.count == 1 {
                pick(contact: contact, rawNumber: contact.phoneNumbers[0])
            } else {
                // More than one number on file — ask which one via the
                // `.confirmationDialog` above rather than guessing.
                contactNumberChoice = contact
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).foregroundStyle(.primary)
                    if contact.phoneNumbers.count == 1 {
                        Text(contact.phoneNumbers[0]).font(.brandCaption).foregroundStyle(.secondary)
                    } else {
                        Text("\(contact.phoneNumbers.count) numbers on file")
                            .font(.brandCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private func pick(contact: DeviceContact, rawNumber: String) {
        contactNumberChoice = nil
        guard let e164 = PhoneNumberFormatting.e164(from: rawNumber) else {
            // Rare for this app's audience (mobile numbers), but a stored
            // number that doesn't shape-check shouldn't just do nothing —
            // see this property's own doc comment.
            pickErrorMessage = "\(contact.name)'s number (\(rawNumber)) doesn't look like a valid phone number — try entering it manually below instead."
            return
        }
        finish(PickedPhoneContact(displayLabel: contact.name, phoneNumber: e164))
    }

    private func finish(_ picked: PickedPhoneContact) {
        onPick(picked)
        dismiss()
    }
}
