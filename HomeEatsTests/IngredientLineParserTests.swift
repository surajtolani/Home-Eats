import XCTest
@testable import HomeEats

final class IngredientLineParserTests: XCTestCase {

    func testParsesSimpleQuantityAndUnit() {
        let entry = IngredientLineParser.parse("2 cups flour")
        XCTAssertEqual(entry.quantity, 2)
        XCTAssertEqual(entry.unit, "cups")
        XCTAssertEqual(entry.name, "flour")
    }

    func testParsesFraction() {
        let entry = IngredientLineParser.parse("1/2 tsp salt")
        XCTAssertEqual(entry.quantity, 0.5)
        XCTAssertEqual(entry.unit, "tsp")
        XCTAssertEqual(entry.name, "salt")
    }

    func testParsesMixedNumber() {
        let entry = IngredientLineParser.parse("1 1/2 lbs chicken breast")
        XCTAssertEqual(entry.quantity, 1.5)
        XCTAssertEqual(entry.unit, "lbs")
        XCTAssertEqual(entry.name, "chicken breast")
    }

    func testParsesLineWithNoUnit() {
        let entry = IngredientLineParser.parse("2 onions, diced")
        XCTAssertEqual(entry.quantity, 2)
        XCTAssertNil(entry.unit)
        XCTAssertEqual(entry.name, "onions, diced")
    }

    func testParsesLineWithNoQuantity() {
        let entry = IngredientLineParser.parse("Salt to taste")
        XCTAssertNil(entry.quantity)
        XCTAssertEqual(entry.name, "Salt to taste")
    }

    func testAssignsCategoryFromKnownKeywords() {
        let entry = IngredientLineParser.parse("2 cups milk")
        XCTAssertEqual(entry.category, .dairyAndEggs)
    }

    func testEmptyLineDoesNotCrash() {
        let entry = IngredientLineParser.parse("   ")
        XCTAssertEqual(entry.name, "")
    }
}
