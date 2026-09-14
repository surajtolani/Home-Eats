import Foundation

/// A fixed, alphabetically-ordered list of US states plus DC, for the
/// profile's State field's `Picker` (`ProfileCompletionStepView`,
/// `EditProfileView`) — direct user request: "in profile, the city, state,
/// country should be from a list... isn't there a way for this to populate
/// from a predetermined list?"
///
/// Same "curated, not pulled from a system data source" approach as
/// `CountryCode.swift` (see its own doc comment) — `Locale` doesn't expose
/// "the US states" as its own enumerable list at all (subdivision codes are
/// per-region and not something Foundation surfaces as a clean, orderable
/// set), so a hand-written list is simpler and more predictable than trying
/// to derive one.
///
/// Deliberately US-only, unlike `CountryCode.all`'s ~53-country spread: a
/// "state" the way this field means it (matching `.textContentType
/// (.addressState)`, which the field used before this became a picker) is a
/// specifically American concept — most other countries' equivalent
/// subdivisions (provinces, counties, prefectures, ...) don't map onto it
/// cleanly, and this app's audience is overwhelmingly US-based (see
/// `CountryCode.all`'s own doc comment on that same assumption, and
/// `CountryCode.default`, which is the US). A non-US account still picks a
/// real value from `Country`; State simply isn't attempting to be
/// meaningful for every country on that list the way Country itself is.
enum USState {
    static let all: [String] = [
        "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado",
        "Connecticut", "Delaware", "District of Columbia", "Florida", "Georgia",
        "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa", "Kansas", "Kentucky",
        "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan",
        "Minnesota", "Mississippi", "Missouri", "Montana", "Nebraska", "Nevada",
        "New Hampshire", "New Jersey", "New Mexico", "New York",
        "North Carolina", "North Dakota", "Ohio", "Oklahoma", "Oregon",
        "Pennsylvania", "Rhode Island", "South Carolina", "South Dakota",
        "Tennessee", "Texas", "Utah", "Vermont", "Virginia", "Washington",
        "West Virginia", "Wisconsin", "Wyoming",
    ]
}
