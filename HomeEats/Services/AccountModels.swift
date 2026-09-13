import Foundation

// Codable models for the backend's accounts/friends/groups/recipe-sharing
// API (see `AccountsAPIClient`, backend/README.md's endpoint table, and
// every file under `backend/routes/` — field names below were checked
// directly against those route files' actual response-building code, not
// just the README's prose summary, since that's the one place a stray
// field-name typo would silently break decoding instead of failing loudly).
//
// A recurring naming note: every `...Id`/`...userId` key the backend sends
// (`createdByUserId`, `ownerId`, `friendshipId`, ...) is remapped here to
// Swift's own `...ID` convention (`createdByUserID`, `ownerID`,
// `friendshipID`) via explicit `CodingKeys` — matching this codebase's
// existing convention for id-suffixed properties (see `createdByMemberID`,
// `proposedByMemberID`, etc. on `Recipe`/`MealSuggestion`/`PlannedMeal`)
// rather than mirroring the backend's own casing verbatim.

/// The caller's own account — `GET /me`'s `user`, and also what
/// `POST /auth/verify-code` returns. `createdAt` is `nil` for the
/// verify-code response (see routes/auth.js — that response's `user` object
/// only ever includes `id`/`phoneNumber`/`displayName`) but present from
/// `GET /me`/`PATCH /me`; optional here so one type can decode both instead
/// of needing two near-identical structs.
struct AccountUser: Codable, Identifiable, Equatable {
    let id: String
    let phoneNumber: String
    let displayName: String?
    let createdAt: Date?

    /// Same fallback idea as `PublicUser.displayNameOrPhoneNumber` — kept as
    /// a separate property on this separate type rather than a shared
    /// protocol, since these two types otherwise have little in common
    /// (`AccountUser` is "me", `PublicUser` is "someone I have a
    /// relationship with") and a protocol just for one shared computed
    /// property would be more machinery than the two-line duplication it
    /// replaces.
    var displayNameOrPhoneNumber: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return phoneNumber
    }
}

/// The subset of a `User` row that's safe to hand back to someone with an
/// actual relationship to that person (an accepted friend, a fellow group
/// member, ...) — mirrors the backend's own `publicUser(...)` helper that
/// every one of routes/friends.js, routes/groups.js, and
/// routes/recipeLibrary.js keeps its own local copy of (see their shared
/// doc comments on why each keeps its own copy rather than importing one).
struct PublicUser: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String?
    let phoneNumber: String

    /// What to show for this person when a display name may or may not be
    /// set yet (`displayName` is `nil` until `PATCH /me` is ever called —
    /// see the `User` model's doc comment in prisma/schema.prisma) — falls
    /// back to the one thing every account always has.
    var displayNameOrPhoneNumber: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return phoneNumber
    }
}

/// One row of `GET /friends`'s `incomingRequests` — a pending request
/// someone else sent *to* the caller, who can accept or decline it.
struct IncomingFriendRequest: Codable, Identifiable {
    let friendshipID: String
    let from: PublicUser
    var id: String { friendshipID }

    enum CodingKeys: String, CodingKey {
        case friendshipID = "friendshipId"
        case from
    }
}

/// One row of `GET /friends`'s `outgoingRequests` — a pending request the
/// caller sent, waiting on the other person. Deliberately has no
/// accept/decline-style action attached: `POST /friends/:friendshipId/decline`
/// is recipient-only (see routes/friends.js's `loadPendingAsRecipient`,
/// which 403s anyone else), and there is no separate "cancel my own
/// outgoing request" route in this API at all — so `FriendsListView` shows
/// these as plain "Pending" rows, not as something with a Cancel button
/// that would just fail.
struct OutgoingFriendRequest: Codable, Identifiable {
    let friendshipID: String
    let to: PublicUser
    var id: String { friendshipID }

    enum CodingKeys: String, CodingKey {
        case friendshipID = "friendshipId"
        case to
    }
}

/// `GET /friends`'s full response — accepted friends plus the two pending
/// lists, exactly as backend/README.md's endpoint table describes it.
struct FriendsList: Codable {
    let friends: [PublicUser]
    let incomingRequests: [IncomingFriendRequest]
    let outgoingRequests: [OutgoingFriendRequest]
}

/// One row of `GET /groups` — the lightweight "which groups am I in" list,
/// with no member list (see `GroupDetail` for that).
struct GroupSummary: Codable, Identifiable {
    let id: String
    let name: String
    /// Nullable: the backend's `Group.createdByUserId` clears (`SetNull`)
    /// rather than cascade-deletes the group when the creator's account is
    /// later deleted — see the doc comment on `Group` in
    /// prisma/schema.prisma — so a group with a deleted creator legitimately
    /// has no value here. Nothing in this app currently reads this field at
    /// all (no "created by ..." UI yet), but it's modeled as optional now so
    /// decoding never crashes on a `null` the moment that UI is added.
    let createdByUserID: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt
        case createdByUserID = "createdByUserId"
    }
}

/// `GET /groups/:groupId`'s (and `POST /groups`'s) full group, including
/// every member's public info — safe here specifically because, per
/// backend/README.md, "everyone returned is a fellow member of this same
/// group."
struct GroupDetail: Codable, Identifiable {
    let id: String
    let name: String
    /// Nullable — see `GroupSummary.createdByUserID`'s doc comment; same
    /// reasoning applies here.
    let createdByUserID: String?
    let createdAt: Date
    let members: [PublicUser]

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, members
        case createdByUserID = "createdByUserId"
    }
}

/// One ingredient on a `RemoteRecipe`, as the backend returns it (it always
/// has an `id`, unlike `RecipeIngredientPayload` — the *outgoing* shape a
/// request body uses, which never includes one; see
/// backend/routes/recipeLibrary.js's PATCH handler doc comment on why an
/// ingredient row's id isn't stable across edits anyway).
struct RemoteIngredient: Codable, Identifiable {
    let id: String
    let name: String
    let quantity: Double?
    let unit: String?
}

/// A recipe as the backend's recipe-library API returns it — the shape
/// `serializeRecipe(...)` in backend/routes/recipeLibrary.js builds for
/// every recipe-returning route except `GET /recipe-library/shared-with-me`
/// (see `SharedRecipeEntry` for that one's extra `share` wrapper).
struct RemoteRecipe: Codable, Identifiable {
    let id: String
    let ownerID: String
    let title: String
    let summary: String?
    let instructions: [String]
    let servings: Int?
    let prepMinutes: Int?
    let cookMinutes: Int?
    /// `"PRIVATE"` or `"SHARED"` (see `RecipeVisibility` in
    /// prisma/schema.prisma) — kept as a plain `String` rather than a Swift
    /// enum since nothing in this app's UI reads it yet (visibility is
    /// implied for the caller: `/mine` is everything you own regardless,
    /// `/shared-with-me` is everything shared with you); a raw string
    /// decodes successfully even if the backend adds a third value (a
    /// documented-as-likely future `PUBLIC` — see backend/README.md) before
    /// this app is updated to know what to do with it, where a
    /// `String`-backed `enum` would instead throw on that unknown case.
    let visibility: String
    let createdAt: Date
    let updatedAt: Date
    let ingredients: [RemoteIngredient]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, instructions, servings, prepMinutes, cookMinutes, visibility, createdAt, updatedAt, ingredients
        case ownerID = "ownerId"
    }
}

/// The `sharedWithGroup` a `RecipeShareInfo` carries when a share was made
/// to a whole group rather than a specific person — just enough to display
/// ("shared via <name>"), not a full `GroupDetail`.
struct SharedGroupInfo: Codable, Identifiable {
    let id: String
    let name: String
}

/// The `share` object `GET /recipe-library/shared-with-me` attaches to each
/// entry — who shared it, when, and via which group if it was a group
/// share rather than a direct one.
struct RecipeShareInfo: Codable, Identifiable {
    let id: String
    let sharedAt: Date
    let sharedBy: PublicUser
    let sharedWithGroup: SharedGroupInfo?
}

/// One row of `GET /recipe-library/shared-with-me` — every field
/// `RemoteRecipe` has, flattened at the top level exactly as the backend
/// sends it (`{ ...serializeRecipe(share.recipe), share: {...} }` in
/// routes/recipeLibrary.js), plus the `share` wrapper. Kept as its own
/// struct rather than `RemoteRecipe` + a nested `share` property so decoding
/// matches the actual flat JSON shape without a custom decoder.
struct SharedRecipeEntry: Codable, Identifiable {
    let recipeID: String
    let ownerID: String
    let title: String
    let summary: String?
    let instructions: [String]
    let servings: Int?
    let prepMinutes: Int?
    let cookMinutes: Int?
    let visibility: String
    let createdAt: Date
    let updatedAt: Date
    let ingredients: [RemoteIngredient]
    let share: RecipeShareInfo

    /// `share.id`, not `recipeID` — on purpose. Per backend/README.md's
    /// `GET /recipe-library/shared-with-me` doc comment: "one entry PER
    /// SHARE (not deduped per-recipe): if the same recipe reached the
    /// caller two ways ... it appears twice." Two such rows have the same
    /// `recipeID` but different `share.id`s, and SwiftUI's `ForEach` needs
    /// a truly unique id to tell them apart — using `recipeID` here would
    /// make the second share of the same recipe silently collide with (and
    /// visually replace) the first.
    var id: String { share.id }

    /// A short, user-facing line for who shared this and how — "Shared by
    /// Priya" or "Shared by Priya via Household", used by
    /// `RecipesHomeView`'s "Shared" section.
    var sharedByCaption: String {
        let name = share.sharedBy.displayNameOrPhoneNumber
        if let groupName = share.sharedWithGroup?.name {
            return "Shared by \(name) via \(groupName)"
        }
        return "Shared by \(name)"
    }

    enum CodingKeys: String, CodingKey {
        case recipeID = "id"
        case title, summary, instructions, servings, prepMinutes, cookMinutes, visibility, createdAt, updatedAt, ingredients, share
        case ownerID = "ownerId"
    }
}
