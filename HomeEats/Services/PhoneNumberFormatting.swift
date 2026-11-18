import Foundation

/// Turns whatever is in a phone number field (typed, pasted, autofilled, or
/// read from Contacts) into the E.164 shape the backend takes: a "+", the
/// country code, then the number. Returns `nil` if it doesn't look like a
/// phone number yet; "Send Code"/"Add"/"Invite" stay disabled until it
/// doesn't.
///
/// This is a quick check that gates buttons, not full validation. The
/// backend (`backend/lib/phone.js`) checks every number against
/// libphonenumber's data for every country and rewrites it to its one
/// canonical form, so leftovers this can't strip without per-country rules
/// (the UK's leading "0" in "+44 07911 123456", for example) are fixed
/// there, and a number that can't exist is refused there with a clear
/// message.
enum PhoneNumberFormatting {
    // Mirrors backend/lib/phone.js's E164_PHONE_REGEX.
    private static let e164Regex = try! NSRegularExpression(pattern: "^\\+[1-9]\\d{6,14}$")

    /// - A number with a "+" already carries its country code (autofill and
    ///   pasted numbers usually look like "+1 (781) 363-3306"), so it is used
    ///   as is, whatever `defaultCountry` says. Prepending a country code to
    ///   it is what used to turn "+1 781…" into "+1 1 781…".
    /// - A number dialed with an international prefix ("00 44 …", or
    ///   "011 44 …" from the US and Canada) is treated the same way.
    /// - Anything else is a national number for `defaultCountry`: the
    ///   picker's selection where there is one, or the phone's own region
    ///   for numbers read from Contacts.
    static func e164(from raw: String, defaultCountry: CountryCode = .default) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isASCIIDigit)

        let candidate: String
        if trimmed.hasPrefix("+") {
            candidate = "+" + digits
        } else if defaultCountry.isNANP {
            // US, Canada and the rest of the +1 zone: always 10 digits,
            // sometimes written with the national "1" in front.
            if digits.hasPrefix("011") {
                candidate = "+" + digits.dropFirst(3)
            } else if digits.count == 10 {
                candidate = "+1" + digits
            } else if digits.count == 11 && digits.hasPrefix("1") {
                candidate = "+" + digits
            } else if defaultCountry.dialCode.count == 5 && digits.count == 7 {
                // A country listed with its area code ("+1876"), and only
                // the 7-digit local number typed.
                candidate = defaultCountry.dialCode + digits
            } else {
                // A partly typed number mustn't pass just because "+1" and a
                // few digits happen to fit the E.164 length range.
                return nil
            }
        } else if digits.hasPrefix("00") {
            candidate = "+" + digits.dropFirst(2)
        } else {
            candidate = defaultCountry.dialCode + digits
        }

        let range = NSRange(candidate.startIndex..., in: candidate)
        return e164Regex.firstMatch(in: candidate, range: range) != nil ? candidate : nil
    }

    /// For a field that already has a country picker: if `raw` carries its
    /// own country code (autofill or paste put "+44 7911 123456" in the
    /// field), returns the country it belongs to and the rest of the number,
    /// so the picker can switch to that country and the field can keep only
    /// the national part. Returns `nil` when `raw` has no "+", or its code
    /// isn't one in `CountryCode.all` (then `e164(from:)` still uses it as
    /// is).
    ///
    /// Several countries share a code (the US and Canada are both +1). When
    /// `current` has the matching code it is kept, otherwise the first match
    /// in the list is used. Either way `e164(from: nationalDigits,
    /// defaultCountry: country)` gives the same number as `e164(from: raw)`,
    /// so the number sent never depends on which flag is shown.
    static func splitInternational(_ raw: String, current: CountryCode) -> (country: CountryCode, nationalDigits: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return nil }
        let digits = trimmed.filter(\.isASCIIDigit)

        let matches = CountryCode.all.filter { country in
            let code = country.dialCode.dropFirst()
            return !code.isEmpty && digits.hasPrefix(code) && digits.count > code.count
        }
        guard let longest = matches.map(\.dialCode.count).max() else { return nil }
        let best = matches.filter { $0.dialCode.count == longest }
        let country = best.first(where: { $0 == current }) ?? best[0]
        let nationalDigits = String(digits.dropFirst(longest - 1))
        // The promise above, checked rather than assumed: the +1 zone's
        // rules (10 digits, or 7 for a code like Jamaica's "+1876") could
        // otherwise read a split number differently from the whole one.
        guard e164(from: nationalDigits, defaultCountry: country) == e164(from: trimmed) else { return nil }
        return (country, nationalDigits)
    }
}

private extension Character {
    /// `Character.isNumber` is also true for digits from other scripts and
    /// for characters like "½", which would put non-ASCII text in the
    /// number.
    var isASCIIDigit: Bool { isASCII && isNumber }
}
