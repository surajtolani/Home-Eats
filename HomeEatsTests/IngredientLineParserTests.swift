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

    // MARK: - Formatting cleanup (unicode fractions, spacing)

    func testParsesUnicodeMixedFraction() {
        let entry = IngredientLineParser.parse("1½ cups flour")
        XCTAssertEqual(entry.quantity, 1.5)
        XCTAssertEqual(entry.unit, "cups")
        XCTAssertEqual(entry.name, "flour")
        XCTAssertEqual(entry.displayText, "1 1/2 cups flour")
    }

    func testParsesBareUnicodeFraction() {
        let entry = IngredientLineParser.parse("½ cup sugar")
        XCTAssertEqual(entry.quantity, 0.5)
        XCTAssertEqual(entry.displayText, "1/2 cup sugar")
    }

    func testParsesUnicodeEighthFraction() {
        let entry = IngredientLineParser.parse("⅛ tsp cinnamon")
        XCTAssertEqual(entry.quantity, 0.125)
        XCTAssertEqual(entry.displayText, "1/8 tsp cinnamon")
    }

    func testCollapsesRepeatedWhitespace() {
        let entry = IngredientLineParser.parse("2   cups    flour")
        XCTAssertEqual(entry.quantity, 2)
        XCTAssertEqual(entry.name, "flour")
        XCTAssertEqual(entry.displayText, "2 cups flour")
    }

    func testCollapsesNonBreakingSpaces() {
        let entry = IngredientLineParser.parse("2\u{00A0}cups\u{00A0}flour")
        XCTAssertEqual(entry.quantity, 2)
        XCTAssertEqual(entry.unit, "cups")
        XCTAssertEqual(entry.name, "flour")
    }

    func testDisplayTextFallsBackToRawTextWhenNoQuantityParsed() {
        let entry = IngredientLineParser.parse("Salt to taste")
        XCTAssertNil(entry.quantity)
        XCTAssertEqual(entry.displayText, "Salt to taste")
    }

    // MARK: - Count-noun units ("loaf", "head", ...)

    func testRecognizesLoafAsAUnit() {
        let entry = IngredientLineParser.parse("1 loaf brioche bread (Cut into thick slices)")
        XCTAssertEqual(entry.quantity, 1)
        XCTAssertEqual(entry.unit, "loaf")
        XCTAssertEqual(entry.name, "brioche bread (Cut into thick slices)")
    }

    func testRecognizesHeadAsAUnit() {
        let entry = IngredientLineParser.parse("2 heads garlic")
        XCTAssertEqual(entry.quantity, 2)
        XCTAssertEqual(entry.unit, "heads")
        XCTAssertEqual(entry.name, "garlic")
    }

    // MARK: - Doubled/nested parentheses

    func testCollapsesDoubledParens() {
        let entry = IngredientLineParser.parse("1 loaf brioche bread ((Cut into thick slices))")
        XCTAssertEqual(entry.name, "brioche bread (Cut into thick slices)")
    }

    func testCollapsesDoubledParensAcrossWhitespace() {
        let entry = IngredientLineParser.parse("1 cup flour ( ( sifted ) )")
        XCTAssertEqual(entry.name, "flour (sifted)")
    }
}
