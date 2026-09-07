import XCTest
@testable import HomeEats

final class IngredientQuantityFormatterTests: XCTestCase {

    func testWholeNumber() {
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 2), "2")
    }

    func testCommonFractions() {
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 0.5), "1/2")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 1.5), "1 1/2")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 0.125), "1/8")
    }

    /// Regression test: ⅕ ⅖ ⅗ ⅘ ⅙ ⅚ are all fractions `IngredientLineParser`
    /// can parse from a unicode glyph, but the display table used to be
    /// missing them — so a parsed 2/5 would silently render as the *nearest
    /// other* fraction (3/8) instead of failing loudly or falling back to a
    /// decimal. That's a correctness bug, not just an ugly one: it shows a
    /// different quantity than what was actually parsed.
    func testFifthsAndSixthsRenderAsThemselvesNotANearbyFraction() {
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 1.0 / 5), "1/5")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 2.0 / 5), "2/5")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 3.0 / 5), "3/5")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 4.0 / 5), "4/5")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 1.0 / 6), "1/6")
        XCTAssertEqual(IngredientQuantityFormatter.string(for: 5.0 / 6), "5/6")
    }

    /// Regression test: summing several 1/3-cup amounts lands on
    /// 0.9999999999999999 due to floating-point error, not exactly 1.0 —
    /// that used to render as the confusing "1.00" instead of "1".
    func testFloatingPointSummationNoiseRoundsToAWholeNumber() {
        let summed = (1.0 / 3) + (1.0 / 3) + (1.0 / 3)
        XCTAssertEqual(IngredientQuantityFormatter.string(for: summed), "1")
    }

    /// Regression test: `Int(_: Double)` traps on a value that doesn't fit
    /// in an `Int` (or isn't finite) — reachable via a huge summed quantity
    /// or a garbled parse. This must degrade gracefully, not crash.
    func testExtremeValuesDoNotCrash() {
        XCTAssertNoThrow(_ = IngredientQuantityFormatter.string(for: 1e19))
        XCTAssertNoThrow(_ = IngredientQuantityFormatter.string(for: .infinity))
        XCTAssertNoThrow(_ = IngredientQuantityFormatter.string(for: .nan))
        XCTAssertNoThrow(_ = IngredientQuantityFormatter.string(for: -1e19))
    }
}
