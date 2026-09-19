import XCTest
@testable import HomeEats

/// Decoding round-trip tests for the Phase 4 group meal-plan/grocery-list
/// wire types (`RemotePlannedMeal`, `RemoteMealSuggestion`, `RemoteGroupGroceryItem`,
/// and the enum conversions each carries) — fixtures hand-checked field by
/// field against the actual serializer functions in
/// `backend/routes/groupMealPlan.js`/`backend/routes/groupGrocery.js`, same
/// discipline `AccountModelsDecodingTests` already applies to the Phase
/// 1-3 types. As with that file: this can't reach the real deployed
/// backend from this environment, so a fixture matching what's hand-copied
/// here is the closest verifiable substitute for "decodes the way the live
/// backend actually responds" — see this task's own final report for that
/// caveat's full scope.
final class GroupSharedPlanDecodingTests: XCTestCase {
    private let decoder = AccountsAPIClient.decoder

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Meal plan (routes/groupMealPlan.js)

    func testGroupMealPlanResponseDecodesPlannedMealsAndSuggestions() throws {
        // Exactly GET /groups/:groupId/meal-plan's response shape —
        // `serializePlannedMeal`/`serializeSuggestion` in
        // routes/groupMealPlan.js.
        let json = """
        {
          "plannedMeals": [
            {
              "id": "pm1", "groupId": "g1", "date": "2024-06-10T00:00:00.000Z", "slot": "DINNER",
              "recipeId": "r1", "restaurantName": null, "isOrderIn": false,
              "decidedByUserId": "u1", "decidedAt": "2024-06-01T12:00:00.000Z"
            },
            {
              "id": "pm2", "groupId": "g1", "date": "2024-06-11T00:00:00.000Z", "slot": "LUNCH",
              "recipeId": null, "restaurantName": "Taco Place", "isOrderIn": true,
              "decidedByUserId": "u2", "decidedAt": "2024-06-02T12:00:00.000Z"
            }
          ],
          "suggestions": [
            {
              "id": "s1", "groupId": "g1", "date": "2024-06-12T00:00:00.000Z", "slot": "BREAKFAST",
              "recipeId": null, "restaurantName": "Diner", "isOrderIn": false,
              "proposedByUserId": "u2", "createdAt": "2024-06-03T09:00:00.000Z",
              "upvoteCount": 2, "downvoteCount": 1, "myVote": "UP"
            }
          ]
        }
        """
        let response = try decoder.decode(GroupMealPlanResponse.self, from: data(json))

        XCTAssertEqual(response.plannedMeals.count, 2)
        let recipeMeal = response.plannedMeals[0]
        XCTAssertEqual(recipeMeal.groupID, "g1")
        XCTAssertEqual(recipeMeal.slot, .dinner)
        XCTAssertEqual(recipeMeal.slot.localSlot, .dinner)
        XCTAssertEqual(recipeMeal.recipeID, "r1")
        XCTAssertNil(recipeMeal.restaurantName)
        XCTAssertEqual(recipeMeal.decidedByUserID, "u1")

        let restaurantMeal = response.plannedMeals[1]
        XCTAssertEqual(restaurantMeal.slot, .lunch)
        XCTAssertNil(restaurantMeal.recipeID)
        XCTAssertEqual(restaurantMeal.restaurantName, "Taco Place")
        XCTAssertTrue(restaurantMeal.isOrderIn)

        XCTAssertEqual(response.suggestions.count, 1)
        let suggestion = response.suggestions[0]
        XCTAssertEqual(suggestion.slot, .breakfast)
        XCTAssertEqual(suggestion.upvoteCount, 2)
        XCTAssertEqual(suggestion.downvoteCount, 1)
        XCTAssertEqual(suggestion.myVote, .up)
        XCTAssertEqual(suggestion.proposedByUserID, "u2")
    }

    /// Regression guard for the caller-having-no-vote case: `myVote` is
    /// `null` (not just absent), and `downvoteCount` can be nonzero on its
    /// own with `upvoteCount` at zero — both must decode cleanly, matching
    /// `serializeSuggestion(...)`'s actual shape in routes/groupMealPlan.js
    /// (it always sends both counts plus `myVote`, `null` when the caller
    /// hasn't voted at all).
    func testRemoteMealSuggestionDecodesWithNoCallerVoteAndOnlyDownvotes() throws {
        struct Fixture: Decodable { let suggestion: RemoteMealSuggestion }
        let json = """
        {
          "suggestion": {
            "id": "s2", "groupId": "g1", "date": "2024-06-13T00:00:00.000Z", "slot": "DINNER",
            "recipeId": null, "restaurantName": "Pizza Place", "isOrderIn": true,
            "proposedByUserId": "u3", "createdAt": "2024-06-04T09:00:00.000Z",
            "upvoteCount": 0, "downvoteCount": 3, "myVote": null
          }
        }
        """
        let response = try decoder.decode(Fixture.self, from: data(json))
        XCTAssertEqual(response.suggestion.upvoteCount, 0)
        XCTAssertEqual(response.suggestion.downvoteCount, 3)
        XCTAssertNil(response.suggestion.myVote)
        // No "voters" key at all in this fixture — same lenient
        // `decodeIfPresent(...) ?? []` `testRemoteMealSuggestionDecodesVoters`'s
        // own doc comment explains; falls back to empty rather than failing
        // the whole decode.
        XCTAssertEqual(response.suggestion.voters, [])
    }

    /// Direct user request: "need to have an ability to see who voted for
    /// each option." `voters` mirrors `serializeSuggestion(...)`'s own
    /// added field in routes/groupMealPlan.js exactly — one entry per vote,
    /// each carrying the voter's id, display name, and direction.
    func testRemoteMealSuggestionDecodesVoters() throws {
        struct Fixture: Decodable { let suggestion: RemoteMealSuggestion }
        let json = """
        {
          "suggestion": {
            "id": "s3", "groupId": "g1", "date": "2024-06-14T00:00:00.000Z", "slot": "LUNCH",
            "recipeId": "r2", "restaurantName": null, "isOrderIn": false,
            "proposedByUserId": "u1", "createdAt": "2024-06-05T09:00:00.000Z",
            "upvoteCount": 2, "downvoteCount": 1, "myVote": "UP",
            "voters": [
              { "userId": "u1", "displayName": "Priya", "direction": "UP" },
              { "userId": "u2", "displayName": "Sam", "direction": "UP" },
              { "userId": "u3", "displayName": "Alex", "direction": "DOWN" }
            ]
          }
        }
        """
        let response = try decoder.decode(Fixture.self, from: data(json))
        XCTAssertEqual(response.suggestion.voters.count, 3)
        XCTAssertEqual(response.suggestion.voters.filter { $0.direction == .up }.map(\.displayName), ["Priya", "Sam"])
        XCTAssertEqual(response.suggestion.voters.filter { $0.direction == .down }.map(\.displayName), ["Alex"])
    }

    /// Regression guard for the one case routes/groupMealPlan.js's own doc
    /// comment on `PlannedMeal.recipeId` calls out explicitly: a decided
    /// meal whose backing recipe was later deleted by its owner
    /// (`onDelete: SetNull`) ends up with BOTH `recipeId` and
    /// `restaurantName` null at once — this must still decode cleanly, not
    /// throw, since the backend can legitimately send exactly this.
    func testRemotePlannedMealDecodesWithBothRecipeAndRestaurantNil() throws {
        struct Fixture: Decodable { let plannedMeal: RemotePlannedMeal }
        let json = """
        {
          "plannedMeal": {
            "id": "pm3", "groupId": "g1", "date": "2024-06-10T00:00:00.000Z", "slot": "OTHER",
            "recipeId": null, "restaurantName": null, "isOrderIn": false,
            "decidedByUserId": "u1", "decidedAt": "2024-06-01T12:00:00.000Z"
          }
        }
        """
        let response = try decoder.decode(Fixture.self, from: data(json))
        XCTAssertNil(response.plannedMeal.recipeID)
        XCTAssertNil(response.plannedMeal.restaurantName)
    }

    func testRemoteMealSlotRoundTripsToAndFromLocalMealSlotForEveryCase() {
        // Every backend spelling maps to exactly the local `MealSlot` case
        // with the matching name — the 1:1 mapping prisma/schema.prisma's
        // `MealSlot` doc comment promises.
        let pairs: [(RemoteMealSlot, MealSlot)] = [
            (.breakfast, .breakfast), (.lunch, .lunch), (.dinner, .dinner), (.other, .other)
        ]
        for (remote, local) in pairs {
            XCTAssertEqual(remote.localSlot, local)
            XCTAssertEqual(RemoteMealSlot(localSlot: local), remote)
        }
    }

    // MARK: - Grocery list (routes/groupGrocery.js)

    func testGroupGroceryListResponseDecodesEveryCategoryAndSection() throws {
        // `serializeItem` in routes/groupGrocery.js — including the Phase 4
        // "My Layout" `aisleId`/`aisleManuallySet` fields, which the real
        // backend always includes (both `nil`/`false` for a never-placed
        // item, and a real id/`true` for one explicitly placed — see the
        // second/third fixture rows below).
        let json = """
        {
          "items": [
            {
              "id": "i1", "groupId": "g1", "name": "milk", "category": "DAIRY_AND_EGGS",
              "section": "THIS_WEEK", "quantityText": "1 gallon", "isChecked": false,
              "orderIndex": 0, "aisleId": null, "aisleManuallySet": false, "addedByUserId": "u1",
              "createdAt": "2024-06-01T00:00:00.000Z", "updatedAt": "2024-06-01T00:00:00.000Z"
            },
            {
              "id": "i2", "groupId": "g1", "name": "paper towels", "category": "HOUSEHOLD",
              "section": "SUGGESTED", "quantityText": "", "isChecked": false,
              "orderIndex": 1.5, "aisleId": null, "aisleManuallySet": false, "addedByUserId": "u2",
              "createdAt": "2024-06-02T00:00:00.000Z", "updatedAt": "2024-06-02T00:00:00.000Z"
            },
            {
              "id": "i3", "groupId": "g1", "name": "napkins", "category": "HOUSEHOLD",
              "section": "THIS_WEEK", "quantityText": "", "isChecked": false,
              "orderIndex": 0, "aisleId": "aisle-1", "aisleManuallySet": true, "addedByUserId": "u1",
              "createdAt": "2024-06-03T00:00:00.000Z", "updatedAt": "2024-06-03T00:00:00.000Z"
            }
          ]
        }
        """
        let response = try decoder.decode(GroupGroceryListResponse.self, from: data(json))
        XCTAssertEqual(response.items.count, 3)

        let milk = response.items[0]
        XCTAssertEqual(milk.category, .dairyAndEggs)
        XCTAssertEqual(milk.category.localCategory, .dairyAndEggs)
        XCTAssertEqual(milk.section, .thisWeek)
        XCTAssertEqual(milk.quantityText, "1 gallon")
        XCTAssertFalse(milk.isChecked)
        XCTAssertNil(milk.aisleID)
        XCTAssertFalse(milk.aisleManuallySet)

        let paperTowels = response.items[1]
        XCTAssertEqual(paperTowels.category, .household)
        XCTAssertEqual(paperTowels.section, .suggested)
        // A fractional Float orderIndex (mid-reorder slot value) decodes
        // into the Double this app stores it as without losing precision.
        XCTAssertEqual(paperTowels.orderIndex, 1.5, accuracy: 0.0001)

        let napkins = response.items[2]
        XCTAssertEqual(napkins.aisleID, "aisle-1")
        XCTAssertTrue(napkins.aisleManuallySet)
    }

    func testRemoteGroceryCategoryRoundTripsToAndFromLocalGroceryCategoryForEveryCase() {
        for local in GroceryCategory.allCases {
            let remote = RemoteGroceryCategory(localCategory: local)
            XCTAssertEqual(remote.localCategory, local)
        }
    }

    func testGroupGrocerySectionHasNoRejectedCase() {
        // Regression guard for the deliberate difference from the local,
        // personal-use `GroceryListSection` (which still has a vestigial
        // `.rejected` case) — see `GroupGrocerySection`'s own doc comment
        // and prisma/schema.prisma's `GroupGrocerySection` doc comment for
        // why this backend enum was never given one to begin with.
        let rawValues = Set(GroupGrocerySection.allCases.map(\.rawValue))
        XCTAssertEqual(rawValues, ["SUGGESTED", "THIS_WEEK", "STAPLES"])
    }

    // MARK: - Group role (routes/groups.js's publicMember)

    func testGroupMemberDecodesRoleForBothCases() throws {
        struct Fixture: Decodable { let members: [GroupMember] }
        // No `phoneNumber` key — matches the backend's `publicMember(...)`
        // shape (routes/groups.js), which stopped including it (see
        // `GroupMember.displayNameOrPhoneNumber`'s own doc comment for why:
        // a real, confirmed abuse vector via the unauthenticated
        // POST /auth/request-code).
        let json = """
        {
          "members": [
            { "id": "u1", "displayName": "Me", "role": "MANAGER" },
            { "id": "u2", "displayName": null, "role": "PARTICIPANT" }
          ]
        }
        """
        let response = try decoder.decode(Fixture.self, from: data(json))
        XCTAssertEqual(response.members[0].role, .manager)
        XCTAssertEqual(response.members[1].role, .participant)
        XCTAssertEqual(response.members[1].displayNameOrPhoneNumber, "New User")
    }
}
