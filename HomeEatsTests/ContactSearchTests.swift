import XCTest
@testable import HomeEats

/// `ContactSearch.filter` is the one piece of `ContactsSearchService` that
/// doesn't touch `CNContactStore` at all — see its own doc comment on why
/// it was factored out specifically to be testable without a real Contacts
/// permission grant, which this test target has no way to provide.
/// `ContactsSearchService` itself (authorization requests, the actual
/// `CNContactStore` fetch) is NOT covered here — that half is only
/// hand-traced, not run, per this task's own verification note.
final class ContactSearchTests: XCTestCase {

    private let alice = DeviceContact(id: "1", name: "Alice Nguyen", phoneNumbers: ["+14155551111"])
    private let bob = DeviceContact(id: "2", name: "Bob Alvarez", phoneNumbers: ["+14155552222"])
    private let charlie = DeviceContact(id: "3", name: "Charlie Osei", phoneNumbers: ["+14155553333", "+14155554444"])

    private var all: [DeviceContact] { [alice, bob, charlie] }

    func testEmptyQueryReturnsEveryContactUnfiltered() {
        XCTAssertEqual(ContactSearch.filter(all, matching: ""), all)
    }

    func testWhitespaceOnlyQueryReturnsEveryContactUnfiltered() {
        XCTAssertEqual(ContactSearch.filter(all, matching: "   "), all)
    }

    func testMatchesOnFirstName() {
        XCTAssertEqual(ContactSearch.filter(all, matching: "alice"), [alice])
    }

    func testMatchesOnLastName() {
        XCTAssertEqual(ContactSearch.filter(all, matching: "alvarez"), [bob])
    }

    /// "al" is a substring of both "Alice" and "Alvarez" — a contact-search
    /// field with no other filter axis should surface both rather than only
    /// prefix-matching the given name.
    func testSubstringMatchAcrossMultipleContactsIsCaseInsensitive() {
        let results = ContactSearch.filter(all, matching: "AL")
        XCTAssertEqual(Set(results), Set([alice, bob]))
    }

    func testNoMatchReturnsEmptyArray() {
        XCTAssertEqual(ContactSearch.filter(all, matching: "Zzyzx"), [])
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertEqual(ContactSearch.filter(all, matching: "  charlie  "), [charlie])
    }

    func testEmptyContactListAlwaysReturnsEmptyRegardlessOfQuery() {
        XCTAssertEqual(ContactSearch.filter([], matching: "anything"), [])
        XCTAssertEqual(ContactSearch.filter([], matching: ""), [])
    }
}
