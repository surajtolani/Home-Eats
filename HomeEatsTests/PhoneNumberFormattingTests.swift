import XCTest
@testable import HomeEats

final class PhoneNumberFormattingTests: XCTestCase {

    // MARK: Bare US numbers (no "+", assumed US/Canada)

    func testTenDigitNumberGetsPlusOnePrefix() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "4155551234"), "+14155551234")
    }

    func testTenDigitNumberWithPunctuationIsNormalized() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "(415) 555-1234"), "+14155551234")
    }

    func testElevenDigitNumberWithLeadingOneJustGetsAPlus() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "1-415-555-1234"), "+14155551234")
    }

    // MARK: Already-international numbers (typed with a leading "+")

    func testAlreadyInternationalNumberIsKeptAsTyped() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "+442071838750"), "+442071838750")
    }

    func testPlusNumberWithPunctuationIsNormalized() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "+1 (415) 555-1234"), "+14155551234")
    }

    // MARK: Rejections — every one of these must disable a "Send Code"/"Send" button

    func testEmptyStringIsInvalid() {
        XCTAssertNil(PhoneNumberFormatting.e164(from: ""))
    }

    func testWhitespaceOnlyIsInvalid() {
        XCTAssertNil(PhoneNumberFormatting.e164(from: "   "))
    }

    /// Regression guard: a bare digit count that's neither a plain 10-digit
    /// US number nor an 11-digit number with a leading "1" must NOT silently
    /// get "+1" glued onto it — that would make a clearly-incomplete number
    /// (e.g. a partially-typed one) pass shape validation anyway.
    func testShortDigitOnlyStringIsInvalidRatherThanGuessed() {
        XCTAssertNil(PhoneNumberFormatting.e164(from: "5551234"))
    }

    func testTooFewDigitsAfterPlusIsInvalid() {
        // The backend's own regex (backend/lib/phone.js) requires a country
        // code digit plus 6-14 more digits — 5 total digits after "+" is
        // one short of that floor.
        XCTAssertNil(PhoneNumberFormatting.e164(from: "+12345"))
    }

    func testLeadingZeroCountryCodeIsInvalid() {
        // E.164 disallows a leading 0 in the country code position.
        XCTAssertNil(PhoneNumberFormatting.e164(from: "+0123456789"))
    }

    func testJustAPlusSignIsInvalid() {
        XCTAssertNil(PhoneNumberFormatting.e164(from: "+"))
    }
}
