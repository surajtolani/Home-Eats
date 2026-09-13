import XCTest
@testable import HomeEats

/// Decoding round-trip tests against hand-written JSON fixtures shaped
/// exactly like what the live backend actually returns — checked field by
/// field against `backend/routes/*.js` while writing these (see each
/// model's own doc comment in `AccountModels.swift` for the specific route
/// each fixture mirrors). These can't reach the real deployed backend from
/// this environment, so this is the closest available substitute: if the
/// backend's actual JSON shape ever drifts from what's hand-copied into
/// these fixtures, decoding here would still pass even though a live call
/// might not — the honest limit of what's verifiable without live network
/// access (see this task's own final report for the rest of that caveat).
final class AccountModelsDecodingTests: XCTestCase {

    /// Every fixture below uses `AccountsAPIClient.decoder` — the exact
    /// decoder the app actually uses at runtime, fractional-seconds date
    /// handling included — rather than a fresh `JSONDecoder()`, so a broken
    /// date strategy would fail here too, not just in production.
    private let decoder = AccountsAPIClient.decoder

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Auth / profile (routes/auth.js, routes/me.js)

    func testVerifyCodeResponseDecodesWithNoDisplayNameOrCreatedAt() throws {
        // Exactly routes/auth.js's POST /verify-code success body — note
        // there's no `createdAt` key at all here, unlike GET /me below.
        struct VerifyResponseFixture: Decodable { let token: String; let user: AccountUser }
        let json = """
        {
          "token": "eyJhbGciOiJIUzI1NiJ9.fake.token",
          "user": { "id": "u1", "phoneNumber": "+14155551234", "displayName": null }
        }
        """
        let response = try decoder.decode(VerifyResponseFixture.self, from: data(json))
        XCTAssertEqual(response.token, "eyJhbGciOiJIUzI1NiJ9.fake.token")
        XCTAssertEqual(response.user.id, "u1")
        XCTAssertEqual(response.user.phoneNumber, "+14155551234")
        XCTAssertNil(response.user.displayName)
        XCTAssertNil(response.user.createdAt)
        XCTAssertEqual(response.user.displayNameOrPhoneNumber, "+14155551234")
    }

    func testGetMeResponseDecodesWithFractionalSecondsCreatedAt() throws {
        // routes/me.js's GET / includes createdAt, serialized by Node's
        // default Date -> JSON as ISO-8601 WITH milliseconds — the exact
        // shape `AccountsAPIClient.decoder`'s custom date strategy exists
        // to handle (see its own doc comment on why plain `.iso8601`
        // wouldn't parse this).
        struct MeResponseFixture: Decodable { let user: AccountUser }
        let json = """
        {
          "user": {
            "id": "u1",
            "phoneNumber": "+14155551234",
            "displayName": "Suraj",
            "createdAt": "2024-01-15T10:30:00.123Z"
          }
        }
        """
        let response = try decoder.decode(MeResponseFixture.self, from: data(json))
        XCTAssertEqual(response.user.displayName, "Suraj")
        XCTAssertEqual(response.user.displayNameOrPhoneNumber, "Suraj")
        let createdAt = try XCTUnwrap(response.user.createdAt)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: createdAt), 2024)
    }

    // MARK: - Friends (routes/friends.js)

    func testFriendsListDecodesAllThreeSections() throws {
        let json = """
        {
          "friends": [
            { "id": "u2", "displayName": "Alex", "phoneNumber": "+14155550002" }
          ],
          "incomingRequests": [
            { "friendshipId": "f1", "from": { "id": "u3", "displayName": null, "phoneNumber": "+14155550003" } }
          ],
          "outgoingRequests": [
            { "friendshipId": "f2", "to": { "id": "u4", "displayName": "Sam", "phoneNumber": "+14155550004" } }
          ]
        }
        """
        let list = try decoder.decode(FriendsList.self, from: data(json))
        XCTAssertEqual(list.friends.count, 1)
        XCTAssertEqual(list.friends[0].displayNameOrPhoneNumber, "Alex")

        XCTAssertEqual(list.incomingRequests.count, 1)
        XCTAssertEqual(list.incomingRequests[0].friendshipID, "f1")
        // No display name yet -> falls back to phone number.
        XCTAssertEqual(list.incomingRequests[0].from.displayNameOrPhoneNumber, "+14155550003")

        XCTAssertEqual(list.outgoingRequests.count, 1)
        XCTAssertEqual(list.outgoingRequests[0].friendshipID, "f2")
        XCTAssertEqual(list.outgoingRequests[0].to.displayNameOrPhoneNumber, "Sam")
    }

    func testFriendsListDecodesWithEmptyRequestLists() throws {
        // The common case for most accounts most of the time — make sure
        // absent friends/requests decode as empty arrays, not a decoding
        // failure or `nil`.
        let json = """
        { "friends": [], "incomingRequests": [], "outgoingRequests": [] }
        """
        let list = try decoder.decode(FriendsList.self, from: data(json))
        XCTAssertTrue(list.friends.isEmpty)
        XCTAssertTrue(list.incomingRequests.isEmpty)
        XCTAssertTrue(list.outgoingRequests.isEmpty)
    }

    // MARK: - Groups (routes/groups.js)

    func testGroupDetailDecodesCreatedByUserIdKeyIntoSwiftCasing() throws {
        struct GroupResponseFixture: Decodable { let group: GroupDetail }
        let json = """
        {
          "group": {
            "id": "g1",
            "name": "Household",
            "createdByUserId": "u1",
            "createdAt": "2024-02-01T00:00:00.000Z",
            "members": [
              { "id": "u1", "displayName": "Me", "phoneNumber": "+14155550001" }
            ]
          }
        }
        """
        let response = try decoder.decode(GroupResponseFixture.self, from: data(json))
        XCTAssertEqual(response.group.createdByUserID, "u1")
        XCTAssertEqual(response.group.members.count, 1)
    }

    // MARK: - Recipe sharing (routes/recipeLibrary.js)

    func testSharedRecipeEntryUsesShareIdNotRecipeIdAsItsIdentity() throws {
        // Regression guard for the exact scenario backend/README.md's own
        // doc comment on GET /recipe-library/shared-with-me calls out: the
        // same recipe shared with the caller two different ways appears as
        // two entries with the SAME "id" (the recipe's id) but different
        // "share.id"s. `SharedRecipeEntry.id` must resolve to the latter, or
        // SwiftUI's `ForEach(sharedRecipes)` would silently collapse these
        // two rows into one.
        struct SharedResponseFixture: Decodable { let recipes: [SharedRecipeEntry] }
        let json = """
        {
          "recipes": [
            {
              "id": "r1", "ownerId": "u2", "title": "Weeknight Chili", "summary": null,
              "instructions": ["Brown the beef.", "Add spices and simmer."],
              "servings": 4, "prepMinutes": 10, "cookMinutes": 30, "visibility": "SHARED",
              "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
              "ingredients": [
                { "id": "i1", "name": "ground beef", "quantity": 1, "unit": "lb" },
                { "id": "i2", "name": "salt", "quantity": null, "unit": null }
              ],
              "share": {
                "id": "s1", "sharedAt": "2024-03-05T09:00:00.000Z",
                "sharedBy": { "id": "u2", "displayName": "Alex", "phoneNumber": "+14155550002" },
                "sharedWithGroup": null
              }
            },
            {
              "id": "r1", "ownerId": "u2", "title": "Weeknight Chili", "summary": null,
              "instructions": ["Brown the beef.", "Add spices and simmer."],
              "servings": 4, "prepMinutes": 10, "cookMinutes": 30, "visibility": "SHARED",
              "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
              "ingredients": [
                { "id": "i1", "name": "ground beef", "quantity": 1, "unit": "lb" },
                { "id": "i2", "name": "salt", "quantity": null, "unit": null }
              ],
              "share": {
                "id": "s2", "sharedAt": "2024-03-06T09:00:00.000Z",
                "sharedBy": { "id": "u2", "displayName": "Alex", "phoneNumber": "+14155550002" },
                "sharedWithGroup": { "id": "g1", "name": "Household" }
              }
            }
          ]
        }
        """
        let response = try decoder.decode(SharedResponseFixture.self, from: data(json))
        XCTAssertEqual(response.recipes.count, 2)

        let direct = response.recipes[0]
        XCTAssertEqual(direct.recipeID, "r1")
        XCTAssertEqual(direct.ownerID, "u2")
        XCTAssertEqual(direct.id, "s1") // share.id, not recipeID
        XCTAssertEqual(direct.ingredients.count, 2)
        XCTAssertEqual(direct.ingredients[1].quantity, nil) // "salt to taste"-style line
        XCTAssertEqual(direct.sharedByCaption, "Shared by Alex")
        XCTAssertNil(direct.share.sharedWithGroup)

        let viaGroup = response.recipes[1]
        XCTAssertEqual(viaGroup.recipeID, "r1") // same recipe...
        XCTAssertEqual(viaGroup.id, "s2")       // ...but a distinct identity
        XCTAssertNotEqual(direct.id, viaGroup.id)
        XCTAssertEqual(viaGroup.sharedByCaption, "Shared by Alex via Household")
    }

    // MARK: - Error shape (every route file's `{ "error": "..." }` responses)

    func testServerErrorResponseDecodesTheSharedErrorShape() throws {
        let json = """
        { "error": "You're already friends." }
        """
        let response = try decoder.decode(AccountsAPIClient.ServerErrorResponse.self, from: data(json))
        XCTAssertEqual(response.error, "You're already friends.")

        // And confirm that message survives being wrapped into the actual
        // error type call sites catch and display.
        let apiError = AccountsAPIError.server(response.error)
        XCTAssertEqual(apiError.errorDescription, "You're already friends.")
    }
}
