import XCTest
@testable import HomeEats

/// Decoding round-trip tests for the Phase 4 "My Layout" aisle wire type
/// (`RemoteGroupStoreAisle`) — same discipline as
/// `GroupSharedPlanDecodingTests`: fixtures hand-checked field by field
/// against the actual serializer function in
/// `backend/routes/groupGroceryAisles.js`. (Two other wire types used to be
/// covered here too: `RemoteGroupStapleItem`/`GroupStaplesResponse` (the
/// standing "staples" template-list feature) and
/// `RemoteGroupGroceryHistoryEntry`/`GroupGroceryHistoryResponse` (the
/// group-shared "past groceries" catalog) — both removed outright along
/// with their whole features; see `GroupStoreAisle`'s doc comment in
/// HomeEats/Models/GroupGroceryLayout.swift for both removal notes.)
final class GroupGroceryLayoutDecodingTests: XCTestCase {
    private let decoder = AccountsAPIClient.decoder

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Aisles (routes/groupGroceryAisles.js)

    func testGroupStoreAislesResponseDecodesStarterAndCustomAisles() throws {
        // `serializeAisle` — a starter aisle carries a non-null
        // `linkedCategory`; a custom, user-typed one always has it `null`.
        let json = """
        {
          "aisles": [
            { "id": "a1", "groupId": "g1", "name": "Produce", "sortIndex": 0, "linkedCategory": "PRODUCE", "createdAt": "2024-06-01T00:00:00.000Z" },
            { "id": "a2", "groupId": "g1", "name": "Aisle 7 - Snacks", "sortIndex": 10, "linkedCategory": null, "createdAt": "2024-06-02T00:00:00.000Z" }
          ]
        }
        """
        let response = try decoder.decode(GroupStoreAislesResponse.self, from: data(json))
        XCTAssertEqual(response.aisles.count, 2)

        let starter = response.aisles[0]
        XCTAssertEqual(starter.groupID, "g1")
        XCTAssertEqual(starter.sortIndex, 0, accuracy: 0.0001)
        XCTAssertEqual(starter.linkedCategory, .produce)
        XCTAssertEqual(starter.linkedCategory?.localCategory, .produce)

        let custom = response.aisles[1]
        XCTAssertEqual(custom.name, "Aisle 7 - Snacks")
        XCTAssertNil(custom.linkedCategory)
    }

    // A "Grocery history" decoding test used to live here too
    // (`GroupGroceryHistoryResponse`, routes/groupGrocery.js's GET
    // .../grocery/history) — removed along with the rest of the
    // group-shared "past groceries" catalog; see `GroupStoreAisle`'s doc
    // comment in HomeEats/Models/GroupGroceryLayout.swift for the removal
    // note.

    // MARK: - `RemoteGroupGroceryItem`'s Phase 4 `aisleId`/`aisleManuallySet` fields

    func testRemoteGroupGroceryItemMemberwiseInitDefaultsAisleFieldsToNotPlaced() {
        // The custom memberwise init (added so pre-Phase-4 call sites/tests
        // keep compiling — see that init's own doc comment) defaults both
        // fields to "never placed" rather than requiring every caller to
        // spell them out.
        let item = RemoteGroupGroceryItem(
            id: "i1", groupID: "g1", name: "Milk", category: .dairyAndEggs, section: .thisWeek,
            quantityText: "1 gal", isChecked: false, orderIndex: 0, addedByUserID: "u1",
            createdAt: .now, updatedAt: .now
        )
        XCTAssertNil(item.aisleID)
        XCTAssertFalse(item.aisleManuallySet)
    }
}

// A `GroupGroceryHistoryEntryIDTests` class used to live here — unit tests
// for `GroupGroceryHistoryEntry.makeID(groupID:name:)`, the pure,
// deterministic local-id derivation `GroupSyncService.reconcileGroceryHistory`
// relied on to match a pulled row against an existing local one. Removed
// along with the rest of the group-shared "past groceries" catalog; see
// `GroupStoreAisle`'s doc comment in HomeEats/Models/GroupGroceryLayout.swift
// for the removal note.

/// Unit tests for the `GroupSyncService.applyRemote(_:to: GroupStoreAisle)`
/// overload — plain field-mapping + `.synced` assignment, exercised directly
/// against in-memory model instances with no `ModelContext` needed, same
/// style as `GroupGroceryItemCreateRaceTests`'s own `applyRemote` coverage.
/// (A second overload used to be covered here too,
/// `applyRemote(_:to: GroupStapleItem)` — its tests were removed along with
/// the rest of the standing "staples" template-list feature; see
/// `GroupStoreAisle`'s doc comment in HomeEats/Models/GroupGroceryLayout.swift
/// for the removal note.)
final class GroupGroceryLayoutApplyRemoteTests: XCTestCase {
    func testApplyRemoteAisleUpdatesEveryFieldAndMarksSynced() {
        let local = GroupStoreAisle(
            id: GroupStoreAisle.newLocalPlaceholderID(), groupID: "g1", name: "Old Name",
            sortIndex: 3, syncState: .pendingUpdate
        )
        let remote = RemoteGroupStoreAisle(
            id: "server-aisle-1", groupID: "g1", name: "New Name", sortIndex: 5,
            linkedCategory: .produce, createdAt: .now
        )
        GroupSyncService.applyRemote(remote, to: local)
        XCTAssertEqual(local.id, "server-aisle-1")
        XCTAssertEqual(local.name, "New Name")
        XCTAssertEqual(local.sortIndex, 5, accuracy: 0.0001)
        XCTAssertEqual(local.linkedCategory, .produce)
        XCTAssertEqual(local.syncState, .synced)
        XCTAssertFalse(local.isLocalPlaceholderID)
    }

    // MARK: - Create-race protection: aisle `sortIndex`
    //
    // Regression test for the same "create call can't communicate field X"
    // race `GroceryCreateReconciliation` closes for `GroupSharedGroceryItem`
    // (see its own doc comment), extended to this Phase 4 model: `POST
    // .../grocery/aisles` never accepts `sortIndex` (a new aisle always
    // lands at the end server-side — see routes/groupGroceryAisles.js), so
    // a local value that already differs from the "always appended at the
    // end" default — whether that happened before the create was ever
    // dispatched, or during its own flight — must win over the create
    // response, and the row must stay push-able (`.pendingUpdate`, not
    // `.synced`) so a follow-up `PATCH` actually corrects the server. (A
    // second model's create-race coverage used to live here too — staple
    // `isActive` — removed along with the rest of the standing "staples"
    // template-list feature; see `GroupStoreAisle`'s doc comment in
    // HomeEats/Models/GroupGroceryLayout.swift for the removal note.)

    func testApplyRemoteAisleWithNoLocalReorder_appliesRemoteSortIndexAndMarksSynced() {
        let local = GroupStoreAisle(
            id: GroupStoreAisle.newLocalPlaceholderID(), groupID: "g1", name: "Snacks",
            sortIndex: 10, syncState: .pendingCreate
        )
        // The create response's own "appended at the end" value — matches
        // what the local row already had, so nothing needs preserving.
        let remote = RemoteGroupStoreAisle(id: "server-aisle-1", groupID: "g1", name: "Snacks", sortIndex: 10, linkedCategory: nil, createdAt: .now)
        GroupSyncService.applyRemote(remote, to: local, preserveLocalSortIndex: false)
        XCTAssertEqual(local.sortIndex, 10, accuracy: 0.0001)
        XCTAssertEqual(local.syncState, .synced)
    }

    /// Regression test for the aisle-`sortIndex` counterpart of the
    /// isChecked/aisle-placement bugs above: the user reordered a still-
    /// `.pendingCreate` aisle — before or during its own create call — which
    /// `POST .../grocery/aisles` has no way to carry, so the create response
    /// always comes back "appended at the end." The local position must
    /// win, and the row must be re-pushed (`.pendingUpdate`) via a follow-up
    /// `PATCH .../grocery/aisles/:id` so the reorder actually reaches the
    /// server.
    func testApplyRemoteAisleAfterLocalReorder_preservesLocalSortIndexAndMarksPendingUpdate() {
        let local = GroupStoreAisle(
            id: GroupStoreAisle.newLocalPlaceholderID(), groupID: "g1", name: "Snacks",
            sortIndex: 2, syncState: .pendingCreate
        )
        let remote = RemoteGroupStoreAisle(id: "server-aisle-1", groupID: "g1", name: "Snacks", sortIndex: 10, linkedCategory: nil, createdAt: .now)
        GroupSyncService.applyRemote(remote, to: local, preserveLocalSortIndex: true)
        XCTAssertEqual(local.sortIndex, 2, accuracy: 0.0001, "local reorder must win, not be reset to \"appended at the end\"")
        XCTAssertEqual(local.syncState, .pendingUpdate, "must be re-pushed, not treated as fully synced")
        XCTAssertFalse(local.isLocalPlaceholderID)
        XCTAssertEqual(local.id, "server-aisle-1")
    }

}
