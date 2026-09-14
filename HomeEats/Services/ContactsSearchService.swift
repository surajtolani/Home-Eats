import Contacts
import Foundation

/// A stripped-down, `Codable`-free view of one `CNContact` — just enough
/// for `ContactOrPhoneNumberPickerView` to show a name and let someone pick
/// one of its phone numbers. Deliberately not `CNContact` itself: leaking
/// that type into the view layer would drag the whole `Contacts` framework
/// (and its own quirks — multi-value fields, contact-key fetch requests,
/// ...) into every view that touches this, for no benefit over a plain
/// struct built once when contacts are fetched.
struct DeviceContact: Identifiable, Hashable {
    /// `CNContact.identifier` — stable for a given contact on this device,
    /// good enough for `Identifiable`/`ForEach` even though it's never sent
    /// anywhere (only the phone number the user actually picks is).
    let id: String
    let name: String
    /// Raw, exactly as stored in Contacts — NOT yet normalized to E.164.
    /// Only contacts with at least one entry here are ever surfaced (see
    /// `ContactsSearchService.fetchContacts`), but a stored number can
    /// still turn out to be something `PhoneNumberFormatting.e164` can't
    /// make sense of (an extension, a landline written unusually, ...) —
    /// that's handled where a number is actually picked, not here.
    let phoneNumbers: [String]
}

/// Pure, dependency-free name filtering over an already-fetched
/// `[DeviceContact]` list — factored out of `ContactsSearchService` itself
/// specifically so this one piece of logic is unit-testable without
/// `CNContactStore`, which needs a real Contacts permission grant/sandbox
/// this app's test target has no way to provide. Filtering happens
/// in-memory over a list fetched once per screen (see
/// `ContactsSearchService.loadIfNeeded`), not re-queried against
/// `CNContactStore` on every keystroke — a local address book is small
/// enough that this is instant, and it means a search can't itself trigger
/// a fresh permission prompt or disk hit while someone's mid-typing.
enum ContactSearch {
    static func filter(_ contacts: [DeviceContact], matching query: String) -> [DeviceContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// Where `ContactsSearchService` currently stands with the OS permission
/// prompt — collapses `CNContactStore`'s own `.restricted` (parental
/// controls, MDM, ...) into the same bucket as `.denied` since this app
/// offers the identical fallback either way (type a number manually, or go
/// fix it in Settings) and has no way to tell a user which of the two
/// applies to them regardless.
enum ContactsAuthorizationState {
    case notRequested
    case authorized
    case denied
}

/// Thin wrapper around Apple's `Contacts` framework for
/// `ContactOrPhoneNumberPickerView`'s "search by name" path — requests
/// authorization once, fetches every phone-having contact once, and hands
/// back a plain `[DeviceContact]` for the view to filter in-memory (see
/// `ContactSearch.filter`). Not a general-purpose contacts service; this app
/// has exactly one feature that needs Contacts access at all.
@MainActor
final class ContactsSearchService: ObservableObject {
    @Published private(set) var contacts: [DeviceContact] = []
    @Published private(set) var authorizationState: ContactsAuthorizationState = .notRequested
    @Published private(set) var isLoading = false

    private let store = CNContactStore()
    /// Guards against re-requesting/re-fetching every time the picker sheet
    /// re-appears within the same instance's lifetime — one fetch per
    /// screen is the stated design (see `ContactSearch`'s doc comment), and
    /// a fresh `ContactsSearchService` is created each time the picker sheet
    /// itself is presented (its `@StateObject`), so this only matters
    /// within a single presentation of that sheet (e.g. SwiftUI re-running
    /// `.task` after a view update).
    private var hasLoaded = false

    /// Requests access (if not already determined) and fetches contacts (if
    /// access is granted) — safe to call from `.task` on every appearance
    /// since it no-ops after the first successful call. Denial (or
    /// restriction) leaves `contacts` empty and sets `authorizationState`
    /// to `.denied` for the view to show its own explanation rather than
    /// an unexplained empty list that looks broken — same "don't let a
    /// permission gate look like a bug" bar `UserLocationProvider`/
    /// `CameraImagePicker`'s callers hold elsewhere in this app, though
    /// unlike location (a "nice to have" that silently degrades) Contacts
    /// denial here gets an explicit message, since without it the whole
    /// "search by name" half of the picker would otherwise just look
    /// empty/broken rather than explained.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }

        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await requestAccess()
        default:
            // .denied, .restricted, and (iOS 18+) .limited all land here —
            // .limited still permits *some* contacts, but this app has no
            // UI for that iOS system picker and treats it the same as a
            // full denial: fall back to manual entry.
            granted = false
        }

        guard granted else {
            authorizationState = .denied
            return
        }
        authorizationState = .authorized
        contacts = await fetchContacts()
    }

    /// `CNContactStore.requestAccess(for:completionHandler:)` predates
    /// Swift concurrency and is callback-only — wrapped here so
    /// `loadIfNeeded` can just `await` it like everything else.
    private func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                // The error CNContactStore hands back here is never
                // surfaced — a denial and an actual fetch error both mean
                // the same thing to this screen ("fall back to manual
                // entry"), and `authorizationStatus(for:)` is checked
                // separately by `loadIfNeeded` for the "why" the view
                // actually shows.
                continuation.resume(returning: granted)
            }
        }
    }

    /// `CNContactStore.enumerateContacts(with:)` is a synchronous, blocking
    /// call — run off the main actor via `Task.detached` so it can't hitch
    /// the UI on a large address book, then hop back for the `@Published`
    /// write in `loadIfNeeded`.
    private func fetchContacts() async -> [DeviceContact] {
        // Explicit `as CNKeyDescriptor` on each plain-`String` key constant —
        // two different real compile errors were hit getting here. First
        // attempt: a trailing `as [CNKeyDescriptor]` cast on the whole array
        // literal, which let the compiler lock in a homogeneous `[String]`
        // from these three keys before it ever considered the cast, then
        // fail to unify that against `descriptorForRequiredKeys`'s
        // `CNKeyDescriptor` return type below. Second attempt: annotating
        // the `let` itself as `[CNKeyDescriptor]`, which flipped the
        // failure instead of fixing it — a plain `String` does NOT
        // implicitly satisfy `any CNKeyDescriptor` as an array-literal
        // element (that protocol requires `NSCopying`/`NSSecureCoding`,
        // which the `NSString` class it bridges to satisfies, but the
        // `String` struct doesn't automatically forward without an
        // explicit bridge). Casting each key individually is what actually
        // works: it's the explicit `String` → `NSString` → `CNKeyDescriptor`
        // bridge Swift needs, applied per-element instead of relying on
        // either whole-array cast direction to infer it.
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            // Required alongside the three keys above whenever fetched
            // contacts are formatted with `CNContactFormatter` (see
            // `CNContactFormatter.string(from:style:)` below) — the real,
            // confirmed cause of a crash reported against this exact method:
            // `.fullName` style internally needs to read additional
            // properties (middle name, name prefix/suffix, phonetic names —
            // exactly which ones depends on the contact's data and the
            // current locale's name ordering) to build a correctly-ordered
            // name, and reading ANY `CNContact` property that wasn't
            // included in `keysToFetch` throws an Objective-C
            // `NSException` — not a Swift `Error`, so the `try?` around
            // `enumerateContacts` below can never catch it; it's an
            // unconditional crash the moment the formatter touches an
            // unfetched property, which is exactly what the real device
            // crash log showed (`-[CNContact middleName]` raising, deep
            // inside `CNContactFormatter`, inside this method). This
            // descriptor is Apple's own documented fix: it expands to
            // whatever full set of keys `CNContactFormatter` might actually
            // need for `.fullName` style, so nothing it reads is ever
            // missing from the fetch again, regardless of a given contact's
            // data or the device's locale/name-order settings.
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        return await Task.detached(priority: .userInitiated) { [store] in
            var results: [DeviceContact] = []
            // `enumerateContacts` can throw if access was revoked between
            // the authorization check above and this call (e.g. the user
            // backgrounds the app and flips the Settings toggle) — treated
            // the same as "no contacts" rather than surfaced as a second
            // error path the view would need to render, since the view
            // already committed to `.authorized` by the time this runs.
            try? store.enumerateContacts(with: request) { contact, _ in
                let numbers = contact.phoneNumbers.map { $0.value.stringValue }
                // Only phone-having contacts are useful for this picker —
                // per this task's own spec ("fetch contacts with at least
                // one phone number"). Filtering here, once, rather than in
                // every view that reads `contacts` later.
                guard !numbers.isEmpty else { return }
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? "\(contact.givenName) \(contact.familyName)"
                        .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                results.append(DeviceContact(id: contact.identifier, name: name, phoneNumbers: numbers))
            }
            return results.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }
}
