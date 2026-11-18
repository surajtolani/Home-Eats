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

    // MARK: Picked country (the sign-in and Add Someone pickers)

    private func country(_ isoCode: String) -> CountryCode {
        CountryCode.all.first { $0.isoCode == isoCode }!
    }

    /// The real bug: autofill put "+1 (781) 363-3306" in the field and the
    /// picker's "+1" was put in front of it, giving "+117813633306".
    func testAutofilledInternationalNumberIgnoresThePickedCountry() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "+1 (781) 363-3306", defaultCountry: country("US")), "+17813633306")
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "+44 7911 123456", defaultCountry: country("US")), "+447911123456")
    }

    func testNationalNumberUsesThePickedCountry() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "7911 123456", defaultCountry: country("GB")), "+447911123456")
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "98765 43210", defaultCountry: country("IN")), "+919876543210")
        // The UK's national "0" is left for the server to drop
        // (backend/lib/phone.js), which knows which countries have one.
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "07911 123456", defaultCountry: country("GB")), "+4407911123456")
    }

    func testInternationalDialingPrefixIsTreatedAsPlus() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "00 44 7911 123456", defaultCountry: country("GB")), "+447911123456")
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "011 44 7911 123456", defaultCountry: country("US")), "+447911123456")
    }

    func testPlusOneZoneNumbers() {
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "1 (781) 363-3306", defaultCountry: country("CA")), "+17813633306")
        XCTAssertNil(PhoneNumberFormatting.e164(from: "781363", defaultCountry: country("CA")))
        // Jamaica is listed as "+1876": the 7-digit local number, or all 10.
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "555 1234", defaultCountry: country("JM")), "+18765551234")
        XCTAssertEqual(PhoneNumberFormatting.e164(from: "876 555 1234", defaultCountry: country("JM")), "+18765551234")
    }

    func testNonASCIIDigitsAreIgnored() {
        XCTAssertNil(PhoneNumberFormatting.e164(from: "+١٢٣٤٥٦٧٨٩٠"))
    }

    // MARK: Moving an autofilled country code into the picker

    func testSplitMovesTheCountryCodeIntoThePicker() {
        let split = PhoneNumberFormatting.splitInternational("+44 7911 123456", current: country("US"))
        XCTAssertEqual(split?.country.isoCode, "GB")
        XCTAssertEqual(split?.nationalDigits, "7911123456")
    }

    func testSplitKeepsThePickedCountryWhenItSharesTheCode() {
        let split = PhoneNumberFormatting.splitInternational("+1 (781) 363-3306", current: country("CA"))
        XCTAssertEqual(split?.country.isoCode, "CA")
        XCTAssertEqual(split?.nationalDigits, "7813633306")
    }

    func testSplitPrefersTheLongestMatchingCode() {
        let split = PhoneNumberFormatting.splitInternational("+1 876 555 1234", current: country("US"))
        XCTAssertEqual(split?.country.isoCode, "JM")
        XCTAssertEqual(split?.nationalDigits, "5551234")
    }

    func testSplitLeavesNumbersWithoutAPlusOrWithAnUnlistedCodeAlone() {
        XCTAssertNil(PhoneNumberFormatting.splitInternational("7813633306", current: country("US")))
        XCTAssertNil(PhoneNumberFormatting.splitInternational("+999 123 456 789", current: country("US")))
        XCTAssertNil(PhoneNumberFormatting.splitInternational("+44", current: country("US")))
    }

    /// Whichever flag is shown, the number sent is the one that was entered.
    func testSplitThenFormatGivesBackTheSameNumber() {
        for raw in ["+1 (781) 363-3306", "+44 7911 123456", "+91 98765 43210", "+1 876 555 1234", "+61 412 345 678"] {
            guard let split = PhoneNumberFormatting.splitInternational(raw, current: .default) else {
                return XCTFail("no split for \(raw)")
            }
            XCTAssertEqual(
                PhoneNumberFormatting.e164(from: split.nationalDigits, defaultCountry: split.country),
                PhoneNumberFormatting.e164(from: raw),
                raw
            )
        }
    }
}
