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

    // MARK: - Rigor pass: real-recipe-sourced edge cases

    /// "a pinch of X" / "a dash of X" never had a digit in front, so the
    /// quantity parser (which required one) left the whole line, article
    /// included, stuck in the name.
    func testParsesImplicitQuantityOfOne() {
        let pinch = IngredientLineParser.parse("a pinch of salt")
        XCTAssertEqual(pinch.quantity, 1)
        XCTAssertEqual(pinch.unit, "pinch")
        XCTAssertEqual(pinch.name, "salt")

        let dash = IngredientLineParser.parse("a dash of hot sauce")
        XCTAssertEqual(dash.quantity, 1)
        XCTAssertEqual(dash.unit, "dash")
        XCTAssertEqual(dash.name, "hot sauce")

        // Only fires when the next word is a real unit — "a large onion"
        // must stay untouched, not get treated as "1 large onion".
        let onion = IngredientLineParser.parse("a large onion")
        XCTAssertNil(onion.quantity)
        XCTAssertEqual(onion.name, "a large onion")
    }

    /// Real recipes ("4-5 cloves garlic", "5-6 large tomatoes") give a
    /// range instead of a single number. Since this app never does
    /// cross-unit arithmetic and only cares about buying enough, the upper
    /// bound is taken as a reasonable estimate.
    func testParsesQuantityRangeAsUpperBound() {
        let cloves = IngredientLineParser.parse("4-5 cloves garlic, minced")
        XCTAssertEqual(cloves.quantity, 5)
        XCTAssertEqual(cloves.unit, "cloves")
        XCTAssertEqual(cloves.name, "garlic, minced")

        // En dash and em dash variants (common in copy-pasted recipe text).
        let enDash = IngredientLineParser.parse("2\u{2013}3 tbsp olive oil")
        XCTAssertEqual(enDash.quantity, 3)
        XCTAssertEqual(enDash.unit, "tbsp")
    }

    /// "scant", "heaping", "rounded", "generous" and the approximation
    /// words "about"/"roughly"/"approximately"/"around" used to block
    /// quantity parsing entirely, since the parser expected a digit first.
    func testParsesQuantityQualifierWords() {
        let scant = IngredientLineParser.parse("scant 1 cup flour")
        XCTAssertEqual(scant.quantity, 1)
        XCTAssertEqual(scant.unit, "cup")
        XCTAssertEqual(scant.name, "flour")

        let about = IngredientLineParser.parse("about 2 tablespoons olive oil")
        XCTAssertEqual(about.quantity, 2)
        XCTAssertEqual(about.unit, "tablespoons")
        XCTAssertEqual(about.name, "olive oil")

        let roughly = IngredientLineParser.parse("roughly 3 cups broth")
        XCTAssertEqual(roughly.quantity, 3)
        XCTAssertEqual(roughly.name, "broth")
    }

    /// Regression: a bare leading digit directly followed by a letter with
    /// no space ("7UP", "10X sugar") was being misread as a real quantity,
    /// corrupting the name into "UP" / "X sugar". Rolls back to treating
    /// the whole line as the name when no real unit follows.
    func testDoesNotMisreadProductNameAsQuantity() {
        let soda = IngredientLineParser.parse("7UP")
        XCTAssertNil(soda.quantity)
        XCTAssertEqual(soda.name, "7UP")

        let sugar = IngredientLineParser.parse("10X sugar")
        XCTAssertNil(sugar.quantity)
        XCTAssertEqual(sugar.name, "10X sugar")

        // A genuine no-space quantity+unit ("2tbsp") must still parse
        // normally — this isn't a general "no space after a digit" ban.
        let realUnit = IngredientLineParser.parse("2tbsp sugar")
        XCTAssertEqual(realUnit.quantity, 2)
        XCTAssertEqual(realUnit.unit, "tbsp")
        XCTAssertEqual(realUnit.name, "sugar")
    }

    /// "1 and 1/2 cups milk" — a mixed number spelled out with "and"
    /// instead of just whitespace.
    func testParsesMixedNumberWithAnd() {
        let entry = IngredientLineParser.parse("1 and 1/2 cups milk")
        XCTAssertEqual(entry.quantity, 1.5)
        XCTAssertEqual(entry.unit, "cups")
        XCTAssertEqual(entry.name, "milk")
    }
}
