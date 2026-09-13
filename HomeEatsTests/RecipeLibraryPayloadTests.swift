import XCTest
@testable import HomeEats

/// `RecipeLibraryPayload.asJSONObject()` builds the exact body
/// `POST /recipe-library`/`PATCH /recipe-library/:id` expect (see
/// `CreateRecipeSchema`/`UpdateRecipeSchema` in
/// backend/routes/recipeLibrary.js) — these tests check the one detail
/// that's easy to get subtly wrong: optional fields must be OMITTED when
/// `nil`, not sent as JSON `null`, since every one of those Zod fields is
/// `.optional()` without `.nullable()`.
final class RecipeLibraryPayloadTests: XCTestCase {

    func testNilOptionalFieldsAreOmittedNotSentAsNull() {
        let recipe = Recipe(
            title: "Toast",
            summary: nil,
            instructions: [],
            ingredients: [],
            servings: 4,
            prepMinutes: 0,
            cookMinutes: 0
        )
        // Force the optional Int fields to nil explicitly, since Recipe's
        // own initializer defaults them to 0, not nil — this test cares
        // about the payload's own nil-handling, not Recipe's defaults.
        var payload = RecipeLibraryPayload(recipe: recipe)
        payload.servings = nil
        payload.prepMinutes = nil
        payload.cookMinutes = nil
        payload.summary = nil

        let object = payload.asJSONObject()

        XCTAssertEqual(object["title"] as? String, "Toast")
        XCTAssertNil(object["summary"], "nil summary must be omitted, not sent as JSON null")
        XCTAssertNil(object["servings"])
        XCTAssertNil(object["prepMinutes"])
        XCTAssertNil(object["cookMinutes"])
        // Required-but-empty arrays are still present (the backend defaults
        // these to [] itself, but there's no reason to rely on that when
        // this client always knows the real list, even an empty one).
        XCTAssertEqual(object["instructions"] as? [String], [])
        XCTAssertEqual((object["ingredients"] as? [[String: Any]])?.count, 0)
    }

    func testPresentOptionalFieldsAreIncluded() throws {
        let recipe = Recipe(
            title: "Weeknight Chili",
            summary: "A quick weeknight favorite.",
            instructions: ["Brown the beef.", "Add spices and simmer."],
            ingredients: [
                RecipeIngredientEntry(name: "ground beef", quantity: 1, unit: "lb"),
                RecipeIngredientEntry(name: "salt", quantity: nil, unit: nil)
            ],
            servings: 6,
            prepMinutes: 10,
            cookMinutes: 30
        )
        let payload = RecipeLibraryPayload(recipe: recipe)
        let object = payload.asJSONObject()

        XCTAssertEqual(object["title"] as? String, "Weeknight Chili")
        XCTAssertEqual(object["summary"] as? String, "A quick weeknight favorite.")
        XCTAssertEqual(object["servings"] as? Int, 6)
        XCTAssertEqual(object["prepMinutes"] as? Int, 10)
        XCTAssertEqual(object["cookMinutes"] as? Int, 30)
        XCTAssertEqual(object["instructions"] as? [String], ["Brown the beef.", "Add spices and simmer."])

        let ingredients = try XCTUnwrap(object["ingredients"] as? [[String: Any]])
        XCTAssertEqual(ingredients.count, 2)
        XCTAssertEqual(ingredients[0]["name"] as? String, "ground beef")
        XCTAssertEqual(ingredients[0]["quantity"] as? Double, 1)
        XCTAssertEqual(ingredients[0]["unit"] as? String, "lb")
        // "salt" has no quantity/unit — both should be omitted, same
        // nil-means-omitted rule as the top-level payload.
        XCTAssertNil(ingredients[1]["quantity"])
        XCTAssertNil(ingredients[1]["unit"])
    }

    /// `Recipe.backendRecipeID` must default to `nil` for every existing
    /// construction path (see its own doc comment on why that's what keeps
    /// adding it a lightweight SwiftData migration) — this is the one part
    /// of that guarantee actually checkable without a real SwiftData store.
    func testBackendRecipeIDDefaultsToNil() {
        let recipe = Recipe(title: "Toast")
        XCTAssertNil(recipe.backendRecipeID)
    }

    func testSharedRecipeSourceCaseExistsAndRoundTripsThroughCodable() throws {
        // RecipeSource is Codable (it's stored as part of Recipe's
        // SwiftData row) — confirm the new `.shared` case encodes/decodes
        // like every other case rather than only compiling.
        let encoded = try JSONEncoder().encode(RecipeSource.shared)
        let decoded = try JSONDecoder().decode(RecipeSource.self, from: encoded)
        XCTAssertEqual(decoded, .shared)
    }

    // MARK: - RecipeLibraryUpdatePayload (PATCH /recipe-library/:id)

    /// `.unchanged` (the default) must leave a nilable field's key out of
    /// the body entirely — the backend reads an omitted key as "don't touch
    /// this field" (see `UpdateRecipeSchema` in
    /// backend/routes/recipeLibrary.js). This is the case every field
    /// defaults to, so an update that only names, say, `title` shouldn't
    /// accidentally also clear `summary`/`servings`/`prepMinutes`/
    /// `cookMinutes`.
    func testUnchangedFieldsAreOmitted() {
        var payload = RecipeLibraryUpdatePayload()
        payload.title = "New Title"

        let object = payload.asJSONObject()

        XCTAssertEqual(object["title"] as? String, "New Title")
        XCTAssertNil(object["summary"], "an untouched field must be omitted, not sent as JSON null")
        XCTAssertNil(object["servings"])
        XCTAssertNil(object["prepMinutes"])
        XCTAssertNil(object["cookMinutes"])
        XCTAssertNil(object["ingredients"])
        XCTAssertNil(object["instructions"])
    }

    /// `.set(nil)` is the "explicitly clear this field" case — this is the
    /// exact bug this type exists to fix: unlike a plain `String?`, this
    /// must actually reach the wire as JSON `null`, not silently vanish
    /// from the body the way assigning Swift's own `nil` through a
    /// `[String: Any]` subscript would.
    func testExplicitNilFieldsAreSentAsJSONNull() {
        var payload = RecipeLibraryUpdatePayload()
        payload.summary = .set(nil)
        payload.servings = .set(nil)
        payload.prepMinutes = .set(nil)
        payload.cookMinutes = .set(nil)

        let object = payload.asJSONObject()

        XCTAssertTrue(object.keys.contains("summary"), "an explicit clear must still be present as a key")
        XCTAssertTrue(object["summary"] is NSNull, "an explicit clear must serialize as JSON null")
        XCTAssertTrue(object["servings"] is NSNull)
        XCTAssertTrue(object["prepMinutes"] is NSNull)
        XCTAssertTrue(object["cookMinutes"] is NSNull)
    }

    /// `.set(value)` must carry the real value through, same as any other
    /// present field.
    func testSetFieldsAreIncludedWithTheirValue() {
        var payload = RecipeLibraryUpdatePayload()
        payload.summary = .set("Updated summary.")
        payload.servings = .set(8)

        let object = payload.asJSONObject()

        XCTAssertEqual(object["summary"] as? String, "Updated summary.")
        XCTAssertEqual(object["servings"] as? Int, 8)
    }

    /// A round trip through `JSONSerialization` itself — belt-and-suspenders
    /// against the `NSNull`-vs-"key absent" distinction being right in this
    /// struct's own `asJSONObject()` but breaking once actually serialized
    /// to bytes and re-parsed (which is what really goes over the wire).
    func testExplicitNilSurvivesRealJSONSerialization() throws {
        var payload = RecipeLibraryUpdatePayload()
        payload.title = "Kept Title"
        payload.summary = .set(nil)

        let data = try JSONSerialization.data(withJSONObject: payload.asJSONObject())
        let reparsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reparsedObject = try XCTUnwrap(reparsed)

        XCTAssertEqual(reparsedObject["title"] as? String, "Kept Title")
        XCTAssertTrue(reparsedObject.keys.contains("summary"))
        XCTAssertTrue(reparsedObject["summary"] is NSNull)
    }
}
