import Foundation

/// Turns whatever someone actually typed into a phone number field into the
/// backend's required E.164 shape — a leading "+", a country code digit 1-9
/// (no leading 0), then 6-14 more digits, exactly matching the regex
/// `backend/lib/phone.js` validates against server-side — or `nil` if it
/// doesn't look like a real number yet. Used to gate "Send Code"/"Send"/
/// "Invite" buttons (disabled until this returns non-`nil`), the same
/// disabled-until-valid convention already used elsewhere in this app (e.g.
/// `RecipeAIImportView.canExtract`), rather than letting an obviously-wrong
/// number reach the network and come back as a server error.
enum PhoneNumberFormatting {
    // Mirrors backend/lib/phone.js's E164_PHONE_REGEX exactly, so a number
    // this accepts is guaranteed to pass the server's own check too (short
    // of Twilio's real deliverability check, which neither side can do
    // without actually sending an SMS).
    private static let e164Regex = try! NSRegularExpression(pattern: "^\\+[1-9]\\d{6,14}$")

    /// This app has no country picker, so a bare 10-digit number (no "+")
    /// is assumed to be US/Canada and gets "+1" prepended automatically —
    /// the common case for this app's household/friends audience. Anyone
    /// with a non-US number can still type (or paste) it with a leading
    /// "+" and their real country code; that's taken as-is and just
    /// re-validated against the same shape, not reinterpreted.
    static func e164(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.hasPrefix("+") {
            // Keep the leading "+", drop everything else that isn't a
            // digit — spaces, dashes, parentheses someone typed purely for
            // readability ("+1 (415) 555-1234").
            candidate = "+" + trimmed.dropFirst().filter(\.isNumber)
        } else {
            let digitsOnly = trimmed.filter(\.isNumber)
            if digitsOnly.count == 10 {
                // The common case: a plain 10-digit US/Canada number with
                // no country code typed at all ("415-555-1234").
                candidate = "+1" + digitsOnly
            } else if digitsOnly.count == 11 && digitsOnly.hasPrefix("1") {
                // Someone typed a leading "1" without a "+" ("1-415-555-1234")
                // — it already has the country code, just needs the "+".
                candidate = "+" + digitsOnly
            } else {
                // Anything else without a "+" isn't a number this app knows
                // how to interpret unambiguously (it can't tell a partial
                // US number from a non-US one typed without its country
                // code) — returning early here rather than guessing a "+1"
                // onto an arbitrary digit count, which could otherwise
                // silently pass the shape check below for a number that
                // isn't actually valid.
                return nil
            }
        }

        let range = NSRange(candidate.startIndex..., in: candidate)
        return e164Regex.firstMatch(in: candidate, range: range) != nil ? candidate : nil
    }
}
