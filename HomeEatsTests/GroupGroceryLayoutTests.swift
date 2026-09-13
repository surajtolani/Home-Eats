import XCTest
@testable import HomeEats

/// Decoding round-trip tests for the Phase 4 "My Layout" aisle/staple/
/// history wire types (`RemoteGroupStoreAisle`, `RemoteGroupStapleItem`,
/// `RemoteGroupGroceryHistoryEntry`) — same discipline as
/// `GroupSharedPlanDecodingTests`: fixtures hand-checked field by field
/// against the actual serializer functions in
/// `backend/routes/groupGroceryAisles.js`/`backend/routes/groupGroceryStaples.js`/
/// `backend/routes/groupGrocery.js`'s `GET .../grocery/history` handler.
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

    // MARK: - Staples (routes/groupGroceryStaples.js)

    func testGroupStaplesResponseDecodesActiveAndInactiveWithOptionalQuantity() throws {
        // `serializeStaple`.
        let json = """
        {
          "staples": [
            { "id": "s1", "groupId": "g1", "name": "Milk", "category": "DAIRY_AND_EGGS", "defaultQuantityText": "1 gallon", "isActive": true, "addedByUserId": "u1", "createdAt": "2024-06-01T00:00:00.000Z" },
            { "id": "s2", "groupId": "g1", "name": "Paper Towels", "category": "HOUSEHOLD", "defaultQuantityText": null, "isActive": false, "addedByUserId": "u2", "createdAt": "2024-06-02T00:00:00.000Z" }
          ]
        }
        """
        let response = try decoder.decode(GroupStaplesResponse.self, from: data(json))
        XCTAssertEqual(response.staples.count, 2)

        let milk = response.staples[0]
        XCTAssertEqual(milk.category, .dairyAndEggs)
        XCTAssertEqual(milk.defaultQuantityText, "1 gallon")
        XCTAssertTrue(milk.isActive)

        let paperTowels = response.staples[1]
        XCTAssertNil(paperTowels.defaultQuantityText)
        XCTAssertFalse(paperTowels.isActive)
    }

    // MARK: - Grocery history (routes/groupGrocery.js's GET .../grocery/history)

    func testGroupGroceryHistoryResponseDecodesTheSmallerReadOnlyShape() throws {
        // Deliberately no `id`/`groupId`/`normalizedName` in this response —
        // see `RemoteGroupGroceryHistoryEntry`'s own doc comment for why.
        let json = """
        {
          "items": [
            { "name": "milk", "category": "DAIRY_AND_EGGS", "addedAt": "2024-06-01T00:00:00.000Z" },
            { "name": "eggs", "category": "DAIRY_AND_EGGS", "addedAt": "2024-06-02T00:00:00.000Z" }
          ]
        }
        """
        let response = try decoder.decode(GroupGroceryHistoryResponse.self, from: data(json))
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].name, "milk")
        XCTAssertEqual(response.items[0].category, .dairyAndEggs)
    }

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

/// Unit tests for `GroupGroceryHistoryEntry.makeID(groupID:name:)` — the
/// pure, deterministic local-id derivation `GroupSyncService
/// .reconcileGroceryHistory` relies on to match a pulled row (which carries
/// no server id of its own — see `RemoteGroupGroceryHistoryEntry`'s own doc
/// comment) against an existing local one, mirroring the backend's own
/// `normalizeHistoryName` dedupe key in routes/groupGrocery.js.
final class GroupGroceryHistoryEntryIDTests: XCTestCase {
    func testSameGroupAndNameProduceTheSameID() {
        let first = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Milk")
        let second = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Milk")
        XCTAssertEqual(first, second)
    }

    func testCaseAndWhitespaceInsensitive() {
        // Same normalization as the backend's `normalizeHistoryName` (trim +
        // lowercase) — "Milk", "milk", and "  MILK  " must all resolve to
        // the same local row, matching one pulled history entry regardless
        // of exactly how its display casing happens to be spelled.
        let a = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Milk")
        let b = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "milk")
        let c = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "  MILK  ")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testDifferentGroupsProduceDifferentIDsForTheSameName() {
        // Group-scoped: the same item name in two different groups must
        // never collide onto the same local row.
        let g1 = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Milk")
        let g2 = GroupGroceryHistoryEntry.makeID(groupID: "g2", name: "Milk")
        XCTAssertNotEqual(g1, g2)
    }

    func testDifferentNamesInTheSameGroupProduceDifferentIDs() {
        let milk = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Milk")
        let eggs = GroupGroceryHistoryEntry.makeID(groupID: "g1", name: "Eggs")
        XCTAssertNotEqual(milk, eggs)
    }
}

/// Unit tests for the new `GroupSyncService.applyRemote` overloads
/// (`RemoteGroupStoreAisle` -> `GroupStoreAisle`, `RemoteGroupStapleItem` ->
/// `GroupStapleItem`) — plain field-mapping + `.synced` assignment, exercised
/// directly against in-memory model instances with no `ModelContext`
/// needed, same style as `GroupGroceryItemCreateRaceTests`'s own
/// `applyRemote` coverage.
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

    func testApplyRemoteStapleUpdatesEveryFieldAndMarksSynced() {
        let local = GroupStapleItem(
            id: GroupStapleItem.newLocalPlaceholderID(), groupID: "g1", name: "Old Name",
            category: .other, isActive: false, addedByUserID: "u1", syncState: .pendingCreate
        )
        let remote = RemoteGroupStapleItem(
            id: "server-staple-1", groupID: "g1", name: "Milk", category: .dairyAndEggs,
            defaultQuantityText: "1 gallon", isActive: true, addedByUserID: "u1", createdAt: .now
        )
        GroupSyncService.applyRemote(remote, to: local)
        XCTAssertEqual(local.id, "server-staple-1")
        XCTAssertEqual(local.name, "Milk")
        XCTAssertEqual(local.category, .dairyAndEggs)
        XCTAssertEqual(local.defaultQuantityText, "1 gallon")
        XCTAssertTrue(local.isActive)
        XCTAssertEqual(local.syncState, .synced)
    }
}
