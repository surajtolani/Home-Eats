import XCTest
@testable import HomeEats

/// Decoding round-trip tests for `GooglePlacesService.searchCities`/
/// `cityDetails(placeID:)` against hand-written JSON fixtures shaped
/// exactly like what `GET /cities/search`/`GET /cities/:placeID` actually
/// return (checked field-by-field against backend/index.js's `predictions`/
/// `{ city, state, country }` response shapes while writing these). Same
/// honest limit as `AccountModelsDecodingTests`'s own doc comment: this
/// can't reach the real deployed backend (or Google) from this sandbox — if
/// the backend's actual JSON shape ever drifts from what's hand-copied
/// here, decoding would still pass even though a live call might not. See
/// this feature's own final report for the separate script that verifies
/// the *backend's* Places-API-shape parsing logic against realistic Google
/// response fixtures — this file only covers the iOS-side decode, one hop
/// further down the chain.
final class GooglePlacesCityDecodingTests: XCTestCase {
    private struct SearchResponseFixture: Decodable {
        let predictions: [GooglePlacesService.CitySuggestion]
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - GET /cities/search

    func testCitySearchResponseDecodesMultiplePredictions() throws {
        let json = """
        {
          "predictions": [
            { "placeID": "ChIJnQ5tX9lQWokR0HeeAd-VXOs", "mainText": "Greenwich", "secondaryText": "CT, USA" },
            { "placeID": "ChIJ68zdT8VZwokRZUq_8fu9UbU", "mainText": "Greenwich Village", "secondaryText": "New York, NY, USA" }
          ]
        }
        """
        let response = try JSONDecoder().decode(SearchResponseFixture.self, from: data(json))
        XCTAssertEqual(response.predictions.count, 2)
        XCTAssertEqual(response.predictions[0].placeID, "ChIJnQ5tX9lQWokR0HeeAd-VXOs")
        XCTAssertEqual(response.predictions[0].mainText, "Greenwich")
        XCTAssertEqual(response.predictions[0].secondaryText, "CT, USA")
        // `Identifiable.id` mirrors `placeID` — same id used to key the
        // dropdown's `ForEach` in CitySearchField.
        XCTAssertEqual(response.predictions[0].id, "ChIJnQ5tX9lQWokR0HeeAd-VXOs")
    }

    /// `secondaryText` is optional on the wire (the backend's own
    /// `structuredFormat?.secondaryText?.text` can be `nil` — see
    /// backend/index.js's GET /cities/search doc comment) — must decode to
    /// `nil` here, not throw, when the key is present-but-null.
    func testCitySearchResponseDecodesWithNullSecondaryText() throws {
        let json = """
        { "predictions": [ { "placeID": "abc123", "mainText": "Greenwich", "secondaryText": null } ] }
        """
        let response = try JSONDecoder().decode(SearchResponseFixture.self, from: data(json))
        XCTAssertEqual(response.predictions.count, 1)
        XCTAssertNil(response.predictions[0].secondaryText)
    }

    /// The common "nothing typed yet" / "no matches" case — an empty
    /// `predictions` array must decode cleanly, matching what `CitySearchField`
    /// treats as "hide the dropdown."
    func testCitySearchResponseDecodesEmptyPredictions() throws {
        let json = """
        { "predictions": [] }
        """
        let response = try JSONDecoder().decode(SearchResponseFixture.self, from: data(json))
        XCTAssertTrue(response.predictions.isEmpty)
    }

    // MARK: - GET /cities/:placeID

    func testCityDetailsDecodesAllThreeFieldsPresent() throws {
        let json = """
        { "city": "Greenwich", "state": "Connecticut", "country": "United States" }
        """
        let details = try JSONDecoder().decode(GooglePlacesService.CityDetails.self, from: data(json))
        XCTAssertEqual(details.city, "Greenwich")
        XCTAssertEqual(details.state, "Connecticut")
        XCTAssertEqual(details.country, "United States")
    }

    /// Regression guard for exactly the scenario `CitySearchField`'s own doc
    /// comment calls out: a place whose Google address components don't
    /// include an `administrative_area_level_1` (e.g. a city-state or a
    /// country with no equivalent subdivision). `state` must decode to
    /// `nil` — a caller checking `if let state = details.state` must not
    /// treat this as an error, just as "nothing to fill in this time."
    func testCityDetailsDecodesWithStateNull() throws {
        let json = """
        { "city": "Singapore", "state": null, "country": "Singapore" }
        """
        let details = try JSONDecoder().decode(GooglePlacesService.CityDetails.self, from: data(json))
        XCTAssertEqual(details.city, "Singapore")
        XCTAssertNil(details.state)
        XCTAssertEqual(details.country, "Singapore")
    }

    /// All three `null` at once — the backend's documented worst case (see
    /// backend/README.md's "City search" section: "any of the three can
    /// legitimately be null"). Must decode without throwing.
    func testCityDetailsDecodesWithAllFieldsNull() throws {
        let json = """
        { "city": null, "state": null, "country": null }
        """
        let details = try JSONDecoder().decode(GooglePlacesService.CityDetails.self, from: data(json))
        XCTAssertNil(details.city)
        XCTAssertNil(details.state)
        XCTAssertNil(details.country)
    }
}
