import Foundation

/// One entry in the sign-in screen's country picker — a flag, a display
/// name, and the dialing code it contributes to the phone number before
/// it's combined with whatever digits someone types (see
/// `AccountSignInView`'s phone step). Deliberately a plain, hand-written
/// list rather than pulling from `Locale`'s region data: this app needs a
/// dial code and a flag per entry, which `Locale` doesn't hand back
/// together in a form worth the indirection for a list this size.
struct CountryCode: Identifiable, Hashable {
    var id: String { isoCode }
    let isoCode: String
    let name: String
    let flag: String
    let dialCode: String

    /// Covers the countries this app's actual audience (friends/family
    /// signing up from wherever they happen to live) is overwhelmingly
    /// likely to be in — not an exhaustive ITU list of every dialing code
    /// in existence. Anyone whose country isn't listed can still type a
    /// full "+<code><number>" directly into the phone field regardless of
    /// what's selected here — see `PhoneNumberFormatting.e164`, which
    /// takes a leading "+" as-is rather than reinterpreting it.
    static let all: [CountryCode] = [
        CountryCode(isoCode: "US", name: "United States", flag: "🇺🇸", dialCode: "+1"),
        CountryCode(isoCode: "CA", name: "Canada", flag: "🇨🇦", dialCode: "+1"),
        CountryCode(isoCode: "MX", name: "Mexico", flag: "🇲🇽", dialCode: "+52"),
        CountryCode(isoCode: "GB", name: "United Kingdom", flag: "🇬🇧", dialCode: "+44"),
        CountryCode(isoCode: "IE", name: "Ireland", flag: "🇮🇪", dialCode: "+353"),
        CountryCode(isoCode: "FR", name: "France", flag: "🇫🇷", dialCode: "+33"),
        CountryCode(isoCode: "DE", name: "Germany", flag: "🇩🇪", dialCode: "+49"),
        CountryCode(isoCode: "ES", name: "Spain", flag: "🇪🇸", dialCode: "+34"),
        CountryCode(isoCode: "PT", name: "Portugal", flag: "🇵🇹", dialCode: "+351"),
        CountryCode(isoCode: "IT", name: "Italy", flag: "🇮🇹", dialCode: "+39"),
        CountryCode(isoCode: "NL", name: "Netherlands", flag: "🇳🇱", dialCode: "+31"),
        CountryCode(isoCode: "BE", name: "Belgium", flag: "🇧🇪", dialCode: "+32"),
        CountryCode(isoCode: "CH", name: "Switzerland", flag: "🇨🇭", dialCode: "+41"),
        CountryCode(isoCode: "AT", name: "Austria", flag: "🇦🇹", dialCode: "+43"),
        CountryCode(isoCode: "SE", name: "Sweden", flag: "🇸🇪", dialCode: "+46"),
        CountryCode(isoCode: "NO", name: "Norway", flag: "🇳🇴", dialCode: "+47"),
        CountryCode(isoCode: "DK", name: "Denmark", flag: "🇩🇰", dialCode: "+45"),
        CountryCode(isoCode: "FI", name: "Finland", flag: "🇫🇮", dialCode: "+358"),
        CountryCode(isoCode: "PL", name: "Poland", flag: "🇵🇱", dialCode: "+48"),
        CountryCode(isoCode: "GR", name: "Greece", flag: "🇬🇷", dialCode: "+30"),
        CountryCode(isoCode: "RO", name: "Romania", flag: "🇷🇴", dialCode: "+40"),
        CountryCode(isoCode: "TR", name: "Turkey", flag: "🇹🇷", dialCode: "+90"),
        CountryCode(isoCode: "RU", name: "Russia", flag: "🇷🇺", dialCode: "+7"),
        CountryCode(isoCode: "UA", name: "Ukraine", flag: "🇺🇦", dialCode: "+380"),
        CountryCode(isoCode: "IL", name: "Israel", flag: "🇮🇱", dialCode: "+972"),
        CountryCode(isoCode: "AE", name: "United Arab Emirates", flag: "🇦🇪", dialCode: "+971"),
        CountryCode(isoCode: "SA", name: "Saudi Arabia", flag: "🇸🇦", dialCode: "+966"),
        CountryCode(isoCode: "EG", name: "Egypt", flag: "🇪🇬", dialCode: "+20"),
        CountryCode(isoCode: "ZA", name: "South Africa", flag: "🇿🇦", dialCode: "+27"),
        CountryCode(isoCode: "NG", name: "Nigeria", flag: "🇳🇬", dialCode: "+234"),
        CountryCode(isoCode: "KE", name: "Kenya", flag: "🇰🇪", dialCode: "+254"),
        CountryCode(isoCode: "IN", name: "India", flag: "🇮🇳", dialCode: "+91"),
        CountryCode(isoCode: "PK", name: "Pakistan", flag: "🇵🇰", dialCode: "+92"),
        CountryCode(isoCode: "BD", name: "Bangladesh", flag: "🇧🇩", dialCode: "+880"),
        CountryCode(isoCode: "CN", name: "China", flag: "🇨🇳", dialCode: "+86"),
        CountryCode(isoCode: "JP", name: "Japan", flag: "🇯🇵", dialCode: "+81"),
        CountryCode(isoCode: "KR", name: "South Korea", flag: "🇰🇷", dialCode: "+82"),
        CountryCode(isoCode: "HK", name: "Hong Kong", flag: "🇭🇰", dialCode: "+852"),
        CountryCode(isoCode: "TW", name: "Taiwan", flag: "🇹🇼", dialCode: "+886"),
        CountryCode(isoCode: "SG", name: "Singapore", flag: "🇸🇬", dialCode: "+65"),
        CountryCode(isoCode: "MY", name: "Malaysia", flag: "🇲🇾", dialCode: "+60"),
        CountryCode(isoCode: "TH", name: "Thailand", flag: "🇹🇭", dialCode: "+66"),
        CountryCode(isoCode: "VN", name: "Vietnam", flag: "🇻🇳", dialCode: "+84"),
        CountryCode(isoCode: "PH", name: "Philippines", flag: "🇵🇭", dialCode: "+63"),
        CountryCode(isoCode: "ID", name: "Indonesia", flag: "🇮🇩", dialCode: "+62"),
        CountryCode(isoCode: "AU", name: "Australia", flag: "🇦🇺", dialCode: "+61"),
        CountryCode(isoCode: "NZ", name: "New Zealand", flag: "🇳🇿", dialCode: "+64"),
        CountryCode(isoCode: "BR", name: "Brazil", flag: "🇧🇷", dialCode: "+55"),
        CountryCode(isoCode: "AR", name: "Argentina", flag: "🇦🇷", dialCode: "+54"),
        CountryCode(isoCode: "CL", name: "Chile", flag: "🇨🇱", dialCode: "+56"),
        CountryCode(isoCode: "CO", name: "Colombia", flag: "🇨🇴", dialCode: "+57"),
        CountryCode(isoCode: "PE", name: "Peru", flag: "🇵🇪", dialCode: "+51"),
        CountryCode(isoCode: "EC", name: "Ecuador", flag: "🇪🇨", dialCode: "+593"),
        CountryCode(isoCode: "VE", name: "Venezuela", flag: "🇻🇪", dialCode: "+58"),
        CountryCode(isoCode: "JM", name: "Jamaica", flag: "🇯🇲", dialCode: "+1876"),
    ]

    static let `default` = all[0] // United States
}
