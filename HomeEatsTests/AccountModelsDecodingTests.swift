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

    func testVerifyCodeResponseDecodesWithNoDisplayNameOrProfileFields() throws {
        // Exactly routes/auth.js's POST /verify-code success body — this
        // used to omit `createdAt` entirely (a smaller, ad-hoc shape from
        // before profile fields existed), but now returns the same full
        // `selfProfile` shape GET/PATCH /me do (see auth.js's doc comment on
        // why: every endpoint that hands back a "self" user object should
        // agree on one shape). `firstName`/`lastName`/`city`/`state`/
        // `country` are all `null` here — the common case right after a
        // brand-new account's very first sign-in, before the post-sign-up
        // profile step has run at all — and `profileComplete` is `false` to
        // match (see routes/me.js's `computeProfileComplete`).
        struct VerifyResponseFixture: Decodable { let token: String; let user: AccountUser }
        let json = """
        {
          "token": "eyJhbGciOiJIUzI1NiJ9.fake.token",
          "user": {
            "id": "u1", "phoneNumber": "+14155551234", "displayName": null,
            "firstName": null, "lastName": null, "city": null, "state": null, "country": null,
            "createdAt": "2024-01-15T10:30:00.123Z", "profileComplete": false
          }
        }
        """
        let response = try decoder.decode(VerifyResponseFixture.self, from: data(json))
        XCTAssertEqual(response.token, "eyJhbGciOiJIUzI1NiJ9.fake.token")
        XCTAssertEqual(response.user.id, "u1")
        XCTAssertEqual(response.user.phoneNumber, "+14155551234")
        XCTAssertNil(response.user.displayName)
        XCTAssertNil(response.user.firstName)
        XCTAssertNil(response.user.state)
        XCTAssertNil(response.user.fullName)
        XCTAssertFalse(response.user.profileComplete)
        XCTAssertEqual(response.user.displayNameOrPhoneNumber, "+14155551234")
    }

    func testGetMeResponseDecodesWithFractionalSecondsCreatedAtAndProfileFields() throws {
        // routes/me.js's GET / includes createdAt, serialized by Node's
        // default Date -> JSON as ISO-8601 WITH milliseconds — the exact
        // shape `AccountsAPIClient.decoder`'s custom date strategy exists
        // to handle (see its own doc comment on why plain `.iso8601`
        // wouldn't parse this). Also covers the full profile-fields case —
        // an account that's completed the mandatory profile step, all five
        // fields set, so `profileComplete` comes back `true`.
        struct MeResponseFixture: Decodable { let user: AccountUser }
        let json = """
        {
          "user": {
            "id": "u1",
            "phoneNumber": "+14155551234",
            "displayName": "Suraj Tolani",
            "firstName": "Suraj",
            "lastName": "Tolani",
            "city": "Greenwich",
            "state": "Connecticut",
            "country": "United States",
            "createdAt": "2024-01-15T10:30:00.123Z",
            "profileComplete": true
          }
        }
        """
        let response = try decoder.decode(MeResponseFixture.self, from: data(json))
        XCTAssertEqual(response.user.displayName, "Suraj Tolani")
        XCTAssertEqual(response.user.displayNameOrPhoneNumber, "Suraj Tolani")
        XCTAssertEqual(response.user.fullName, "Suraj Tolani")
        XCTAssertEqual(response.user.city, "Greenwich")
        XCTAssertEqual(response.user.state, "Connecticut")
        XCTAssertEqual(response.user.country, "United States")
        XCTAssertTrue(response.user.profileComplete)
        let createdAt = response.user.createdAt
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: createdAt), 2024)
    }

    /// Regression guard for the specific design choice `AccountUser.profileComplete`
    /// makes (see that property's own doc comment): it's decoded straight off
    /// the wire, never recomputed client-side from the other five fields. A
    /// account with `state` still unset but a (deliberately unrealistic,
    /// backend-would-never-actually-send-this) `profileComplete: true` must
    /// still decode to `true` here — if this type instead derived the value
    /// itself from the five fields, this exact fixture would silently give
    /// the opposite answer and this test would catch that divergence.
    func testProfileCompleteIsDecodedFromTheWireNotRecomputedLocally() throws {
        struct MeResponseFixture: Decodable { let user: AccountUser }
        let json = """
        {
          "user": {
            "id": "u1", "phoneNumber": "+14155551234", "displayName": "Test User",
            "firstName": "Test", "lastName": "User", "city": "Boise", "state": null, "country": "USA",
            "createdAt": "2024-01-15T10:30:00.123Z", "profileComplete": true
          }
        }
        """
        let response = try decoder.decode(MeResponseFixture.self, from: data(json))
        XCTAssertNil(response.user.state)
        XCTAssertTrue(response.user.profileComplete)
    }

    /// The exact scenario `PATCH /me`'s field-at-a-time semantics make
    /// routine — `computeProfileComplete` flips `false` -> `true` only once
    /// EVERY ONE of the five fields is set, not as soon as some of them are
    /// (see routes/me.js's own doc comment). This fixture is the "four of
    /// five" moment — everything but `state` — where a bug that required
    /// only firstName/lastName (the old, pre-this-change bar) would
    /// incorrectly read as complete.
    func testProfileCompleteIsFalseWhenOnlyStateIsMissing() throws {
        struct MeResponseFixture: Decodable { let user: AccountUser }
        let json = """
        {
          "user": {
            "id": "u1", "phoneNumber": "+14155551234", "displayName": "Bob Resumed",
            "firstName": "Bob", "lastName": "Resumed", "city": "Boise", "state": null, "country": "USA",
            "createdAt": "2024-01-15T10:30:00.123Z", "profileComplete": false
          }
        }
        """
        let response = try decoder.decode(MeResponseFixture.self, from: data(json))
        XCTAssertEqual(response.user.firstName, "Bob")
        XCTAssertNil(response.user.state)
        XCTAssertFalse(response.user.profileComplete)
    }

    // MARK: - Friends (routes/friends.js)

    func testFriendsListDecodesAllThreeSections() throws {
        // No `phoneNumber` key anywhere here — matches the backend's
        // `publicUser(...)` shape (routes/friends.js), which stopped
        // including it (see `PublicUser.displayNameOrPhoneNumber`'s own doc
        // comment for why: a real, confirmed abuse vector via the
        // unauthenticated POST /auth/request-code).
        let json = """
        {
          "friends": [
            { "id": "u2", "displayName": "Alex" }
          ],
          "incomingRequests": [
            { "friendshipId": "f1", "from": { "id": "u3", "displayName": null } }
          ],
          "outgoingRequests": [
            { "friendshipId": "f2", "to": { "id": "u4", "displayName": "Sam" } }
          ]
        }
        """
        let list = try decoder.decode(FriendsList.self, from: data(json))
        XCTAssertEqual(list.friends.count, 1)
        XCTAssertEqual(list.friends[0].displayNameOrPhoneNumber, "Alex")

        XCTAssertEqual(list.incomingRequests.count, 1)
        XCTAssertEqual(list.incomingRequests[0].friendshipID, "f1")
        // No display name yet -> falls back to a generic placeholder, never
        // a phone number.
        XCTAssertEqual(list.incomingRequests[0].from.displayNameOrPhoneNumber, "New User")

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
        // `members` now includes each membership's `role` (Phase 3 — see
        // `publicMember(...)` in routes/groups.js and backend/README.md's
        // "Group roles" section) — this fixture carries both roles so the
        // decode itself, and `myRole(currentUserID:)` below, are both
        // exercised against a realistic multi-member response.
        let json = """
        {
          "group": {
            "id": "g1",
            "name": "Household",
            "createdByUserId": "u1",
            "createdAt": "2024-02-01T00:00:00.000Z",
            "members": [
              { "id": "u1", "displayName": "Me", "role": "MANAGER" },
              { "id": "u2", "displayName": "Alex", "role": "PARTICIPANT" }
            ]
          }
        }
        """
        let response = try decoder.decode(GroupResponseFixture.self, from: data(json))
        XCTAssertEqual(response.group.createdByUserID, "u1")
        XCTAssertEqual(response.group.members.count, 2)
        XCTAssertEqual(response.group.members[0].role, .manager)
        XCTAssertEqual(response.group.members[1].role, .participant)
        XCTAssertEqual(response.group.myRole(currentUserID: "u1"), .manager)
        XCTAssertEqual(response.group.myRole(currentUserID: "u2"), .participant)
        // A caller id that isn't in `members` at all (shouldn't happen in
        // practice — see `myRole`'s own doc comment) resolves to `nil`
        // rather than crashing.
        XCTAssertNil(response.group.myRole(currentUserID: "u3"))
        XCTAssertNil(response.group.myRole(currentUserID: nil))
    }

    /// `Group.createdByUserId` is nullable on the backend (`onDelete:
    /// SetNull` — see the `Group` doc comment in prisma/schema.prisma): the
    /// creator's account can be deleted later without taking the group down
    /// with it, leaving this field `null`. Regression guard for exactly that
    /// response shape — this must decode cleanly, not throw.
    func testGroupDetailDecodesNullCreatedByUserId() throws {
        struct GroupResponseFixture: Decodable { let group: GroupDetail }
        let json = """
        {
          "group": {
            "id": "g1",
            "name": "Household",
            "createdByUserId": null,
            "createdAt": "2024-02-01T00:00:00.000Z",
            "members": [
              { "id": "u1", "displayName": "Me", "role": "PARTICIPANT" }
            ]
          }
        }
        """
        let response = try decoder.decode(GroupResponseFixture.self, from: data(json))
        XCTAssertNil(response.group.createdByUserID)
    }

    // MARK: - Invites, promote/demote, notifications (Phase 5 — routes/invites.js, routes/notifications.js, routes/groups.js)

    /// Exactly `GET /invites`'s response shape — checked directly against a
    /// real local backend (mint a JWT, `POST /groups/:groupId/invite`,
    /// `GET /invites` as the recipient) while writing this fixture, not just
    /// copied from routes/invites.js's `serializeGroupInvite`.
    func testGroupInviteListDecodes() throws {
        struct InvitesResponseFixture: Decodable { let invites: [GroupInvite] }
        let json = """
        {
          "invites": [
            {
              "id": "inv1",
              "group": { "id": "g1", "name": "Trip" },
              "invitedBy": { "id": "u1", "displayName": "Alice", "phoneNumber": "+15550000001" },
              "createdAt": "2026-09-14T00:12:49.024Z"
            }
          ]
        }
        """
        let response = try decoder.decode(InvitesResponseFixture.self, from: data(json))
        XCTAssertEqual(response.invites.count, 1)
        XCTAssertEqual(response.invites[0].group.name, "Trip")
        XCTAssertEqual(response.invites[0].invitedBy.displayNameOrPhoneNumber, "Alice")
    }

    /// `GET /notifications`'s combined feed — `friendRequests`/`groupInvites`
    /// decode into the exact same `IncomingFriendRequest`/`GroupInvite` types
    /// `GET /friends`/`GET /invites` already use (see `NotificationsFeed`'s
    /// own doc comment on why there's no third shape), verified here with
    /// one of each present at once plus a `count` that's their sum — exactly
    /// what a live `GET /notifications` call returned while writing this
    /// fixture.
    func testNotificationsFeedDecodesBothListsAndCount() throws {
        let json = """
        {
          "count": 2,
          "friendRequests": [
            { "friendshipId": "f1", "from": { "id": "u3", "displayName": "Sam", "phoneNumber": "+14155550003" } }
          ],
          "groupInvites": [
            {
              "id": "inv1",
              "group": { "id": "g1", "name": "Trip" },
              "invitedBy": { "id": "u1", "displayName": "Alice", "phoneNumber": "+15550000001" },
              "createdAt": "2026-09-14T00:12:49.024Z"
            }
          ]
        }
        """
        let feed = try decoder.decode(NotificationsFeed.self, from: data(json))
        XCTAssertEqual(feed.count, 2)
        XCTAssertEqual(feed.friendRequests.count, 1)
        XCTAssertEqual(feed.friendRequests[0].from.displayNameOrPhoneNumber, "Sam")
        XCTAssertEqual(feed.groupInvites.count, 1)
        XCTAssertEqual(feed.groupInvites[0].group.name, "Trip")
    }

    /// The empty case — no friend requests, no group invites — must decode
    /// to `count == 0` and two empty arrays, not `nil`/a decoding failure;
    /// this is what the notification bell should show as "no badge."
    func testNotificationsFeedDecodesEmpty() throws {
        let json = """
        { "count": 0, "friendRequests": [], "groupInvites": [] }
        """
        let feed = try decoder.decode(NotificationsFeed.self, from: data(json))
        XCTAssertEqual(feed.count, 0)
        XCTAssertTrue(feed.friendRequests.isEmpty)
        XCTAssertTrue(feed.groupInvites.isEmpty)
    }

    /// `GET /groups/:groupId/invites` — the new, not-part-of-Phase-5 route
    /// added for `GroupDetailView`'s "Pending Invites" section (see
    /// `GroupSentInvite`'s own doc comment). Checked directly against a real
    /// local backend: one `PENDING` invite where `invitedPhoneNumber`
    /// already belongs to a user (`invitedUser` non-`nil`), and one
    /// `DECLINED` invite — the two statuses this app's UI actually branches
    /// on (`GroupInviteStatus`'s own doc comment).
    func testGroupSentInvitesDecodePendingAndDeclinedWithAndWithoutInvitedUser() throws {
        struct SentInvitesResponseFixture: Decodable { let invites: [GroupSentInvite] }
        let json = """
        {
          "invites": [
            {
              "id": "inv1",
              "invitedPhoneNumber": "+15550000003",
              "invitedUser": { "id": "u3", "displayName": "Carol", "phoneNumber": "+15550000003" },
              "invitedBy": { "id": "u1", "displayName": "Alice", "phoneNumber": "+15550000001" },
              "status": "PENDING",
              "createdAt": "2026-09-14T00:13:30.957Z"
            },
            {
              "id": "inv2",
              "invitedPhoneNumber": "+15550000009",
              "invitedUser": null,
              "invitedBy": { "id": "u1", "displayName": "Alice", "phoneNumber": "+15550000001" },
              "status": "DECLINED",
              "createdAt": "2026-09-14T00:13:21.206Z"
            }
          ]
        }
        """
        let response = try decoder.decode(SentInvitesResponseFixture.self, from: data(json))
        XCTAssertEqual(response.invites.count, 2)

        let pending = response.invites[0]
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.invitedUser?.displayNameOrPhoneNumber, "Carol")
        XCTAssertEqual(pending.displayLabel, "Carol") // known user -> name, not raw number

        let declined = response.invites[1]
        XCTAssertEqual(declined.status, .declined)
        XCTAssertNil(declined.invitedUser)
        XCTAssertEqual(declined.displayLabel, "+15550000009") // unknown -> falls back to the raw number
    }

    /// Regression guard for a real, confirmed leak fix: `GET
    /// /:groupId/invites` used to send back `invitedPhoneNumber`
    /// unconditionally to any fellow manager, not just whoever actually
    /// created that invite — see `GroupSentInvite.invitedPhoneNumber`'s own
    /// doc comment. The backend now sends `null` for an invite this viewer
    /// didn't create; this checks that decodes cleanly (not a decode
    /// failure from a suddenly-non-optional field) and that `displayLabel`
    /// falls back to something that doesn't invent a phone number that was
    /// never actually sent.
    func testGroupSentInviteWithNoPhoneNumberFallsBackSafely() throws {
        struct SentInvitesResponseFixture: Decodable { let invites: [GroupSentInvite] }
        let json = """
        {
          "invites": [
            {
              "id": "inv3",
              "invitedPhoneNumber": null,
              "invitedUser": null,
              "invitedBy": { "id": "u2", "displayName": "Bob", "phoneNumber": "+15550000002" },
              "status": "DECLINED",
              "createdAt": "2026-09-14T00:13:21.206Z"
            }
          ]
        }
        """
        let response = try decoder.decode(SentInvitesResponseFixture.self, from: data(json))
        let invite = response.invites[0]
        XCTAssertNil(invite.invitedPhoneNumber)
        XCTAssertEqual(invite.displayLabel, "Phone invite") // no number, no known user -> generic, not a crash/blank
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

    /// `RemoteRecipe` (the shape `POST/GET/PATCH /recipe-library`(`/:id`)
    /// all return) with a photo present — regression guard for the bug this
    /// field exists to fix: recipe photos used to be purely local, so a
    /// shared recipe never carried one across at all. `photoBase64` here is
    /// a tiny 1x1 fixture (not a real photo — the actual bytes don't matter
    /// for a decode test, only that the string round-trips and
    /// `photoData`'s base64 decode succeeds).
    func testRemoteRecipeDecodesWithPhotoBase64Present() throws {
        struct RecipeResponseFixture: Decodable { let recipe: RemoteRecipe }
        let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let json = """
        {
          "recipe": {
            "id": "r1", "ownerId": "u1", "title": "Weeknight Chili", "summary": null,
            "instructions": ["Brown the beef."],
            "servings": 4, "prepMinutes": 10, "cookMinutes": 30, "visibility": "PRIVATE",
            "photoBase64": "\(tinyPNGBase64)",
            "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
            "ingredients": []
          }
        }
        """
        let response = try decoder.decode(RecipeResponseFixture.self, from: data(json))
        XCTAssertEqual(response.recipe.photoBase64, tinyPNGBase64)
        let decodedPhoto = try XCTUnwrap(response.recipe.photoData)
        XCTAssertFalse(decodedPhoto.isEmpty)
    }

    /// The common case: no photo at all. `photoBase64` must decode as `nil`
    /// cleanly (not throw) whether the backend omits the key entirely or
    /// sends an explicit JSON `null` — `serializeRecipe(...)` in
    /// routes/recipeLibrary.js always sends the key with a `null` value for
    /// a photo-less recipe (a plain JS `undefined`/`null` field still
    /// appears in `res.json(...)`'s output as `null`, not an omitted key),
    /// so this fixture matches that exact shape rather than omitting the
    /// key, which would only prove the *more* lenient case works.
    func testRemoteRecipeDecodesWithNullPhotoBase64() throws {
        struct RecipeResponseFixture: Decodable { let recipe: RemoteRecipe }
        let json = """
        {
          "recipe": {
            "id": "r1", "ownerId": "u1", "title": "Weeknight Chili", "summary": null,
            "instructions": ["Brown the beef."],
            "servings": 4, "prepMinutes": 10, "cookMinutes": 30, "visibility": "PRIVATE",
            "photoBase64": null,
            "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
            "ingredients": []
          }
        }
        """
        let response = try decoder.decode(RecipeResponseFixture.self, from: data(json))
        XCTAssertNil(response.recipe.photoBase64)
        XCTAssertNil(response.recipe.photoData)
    }

    /// Same field, same "present vs. null" pair, on `SharedRecipeEntry` —
    /// this is the shape that actually matters most for the reported bug,
    /// since it's what powers `RecipesHomeView`'s "Shared" section and
    /// `saveSharedRecipe(_:)`'s `photoData: entry.photoData`.
    func testSharedRecipeEntryDecodesPhotoBase64PresentAndNull() throws {
        struct SharedResponseFixture: Decodable { let recipes: [SharedRecipeEntry] }
        let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let json = """
        {
          "recipes": [
            {
              "id": "r1", "ownerId": "u2", "title": "Weeknight Chili", "summary": null,
              "instructions": ["Brown the beef."],
              "servings": 4, "prepMinutes": 10, "cookMinutes": 30, "visibility": "SHARED",
              "photoBase64": "\(tinyPNGBase64)",
              "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
              "ingredients": [],
              "share": {
                "id": "s1", "sharedAt": "2024-03-05T09:00:00.000Z",
                "sharedBy": { "id": "u2", "displayName": "Alex", "phoneNumber": "+14155550002" },
                "sharedWithGroup": null
              }
            },
            {
              "id": "r2", "ownerId": "u2", "title": "Plain Toast", "summary": null,
              "instructions": ["Toast the bread."],
              "servings": 1, "prepMinutes": 1, "cookMinutes": 2, "visibility": "SHARED",
              "photoBase64": null,
              "createdAt": "2024-03-01T12:00:00.000Z", "updatedAt": "2024-03-02T08:15:30.500Z",
              "ingredients": [],
              "share": {
                "id": "s2", "sharedAt": "2024-03-05T09:00:00.000Z",
                "sharedBy": { "id": "u2", "displayName": "Alex", "phoneNumber": "+14155550002" },
                "sharedWithGroup": null
              }
            }
          ]
        }
        """
        let response = try decoder.decode(SharedResponseFixture.self, from: data(json))
        XCTAssertEqual(response.recipes.count, 2)

        let withPhoto = response.recipes[0]
        XCTAssertEqual(withPhoto.photoBase64, tinyPNGBase64)
        let decodedPhoto = try XCTUnwrap(withPhoto.photoData)
        XCTAssertFalse(decodedPhoto.isEmpty)

        let withoutPhoto = response.recipes[1]
        XCTAssertNil(withoutPhoto.photoBase64)
        XCTAssertNil(withoutPhoto.photoData)
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
