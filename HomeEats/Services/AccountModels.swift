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
/// `POST /auth/verify-code` returns. Every field here is present in both
/// responses (see routes/auth.js's `selfProfile`-matching verify-code
/// response, added alongside these profile fields — before that, verify-code
/// used to return a smaller ad-hoc shape, which is why `createdAt` used to
/// be modeled as optional here; now both endpoints genuinely agree on one
/// shape, so one non-optional type covers both with no compromise).
struct AccountUser: Codable, Identifiable, Equatable {
    let id: String
    let phoneNumber: String
    let displayName: String?
    /// First/last name and city/country (see routes/me.js's `selfProfile`) —
    /// all independently optional: `firstName`/`lastName` are asked for once
    /// at the end of sign-up (see `AccountSignInView`'s name step) but
    /// nothing stops a still-unnamed account existing briefly in between,
    /// and `city`/`country` are never asked for at sign-up at all (that
    /// would add friction to first launch for no immediate payoff) — only
    /// ever set later, if at all, via `EditProfileView`.
    let firstName: String?
    let lastName: String?
    let city: String?
    let country: String?
    let createdAt: Date

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

    /// `firstName` + `lastName` joined with a space, trimmed — `nil` if
    /// neither is set. Used to build `displayName` automatically from the
    /// sign-up name step rather than asking for a separate "display name"
    /// on top of the two fields it's already collecting (see
    /// `AccountSignInView.saveName()`).
    var fullName: String? {
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
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

/// `GroupMembership.role` (Phase 3 — see the `GroupRole` doc comment in
/// prisma/schema.prisma): `MANAGER` can decide/add directly onto a group's
/// shared meal plan and grocery list; `PARTICIPANT` can only propose/suggest
/// and do routine list upkeep (checking an item off, reordering) — see
/// `routes/groupMealPlan.js`/`routes/groupGrocery.js` for the exact,
/// sometimes field-grained, rules each new screen's role gating mirrors.
/// Modeled as a real Swift enum (not a raw `String`, unlike
/// `RemoteRecipe.visibility` — see that property's own doc comment on why a
/// raw string was right there): unlike `visibility`, this app's new group
/// screens genuinely branch UI on every value this can take, so a `String`
/// that could silently fail to match anything would just move a decoding
/// failure into a harder-to-spot logic bug instead.
enum GroupRole: String, Codable {
    case manager = "MANAGER"
    case participant = "PARTICIPANT"
}

/// One entry of `GroupDetail.members` — everything `PublicUser` has, plus
/// this membership's `role` (see `publicMember(...)` in routes/groups.js,
/// added in Phase 3). Kept as its own type rather than folding `role` onto
/// `PublicUser` itself: `PublicUser` is still exactly right, role-less, for
/// every context that has no membership to speak of (the friends list,
/// recipe-share pickers, ...) — adding an unused `role` there would mean
/// either a bogus placeholder value or making it optional everywhere for
/// this one case's benefit.
struct GroupMember: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String?
    let phoneNumber: String
    let role: GroupRole

    /// Same fallback idea as `PublicUser.displayNameOrPhoneNumber` — kept as
    /// its own copy rather than a shared protocol, same reasoning as that
    /// property's own doc comment.
    var displayNameOrPhoneNumber: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return phoneNumber
    }
}

/// `GET /groups/:groupId`'s (and `POST /groups`'s) full group, including
/// every member's public info and role — safe here specifically because, per
/// backend/README.md, "everyone returned is a fellow member of this same
/// group."
struct GroupDetail: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Nullable — see `GroupSummary.createdByUserID`'s doc comment; same
    /// reasoning applies here.
    let createdByUserID: String?
    let createdAt: Date
    let members: [GroupMember]

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, members
        case createdByUserID = "createdByUserId"
    }

    // Equatable/Hashable by `id` alone (not every field — `members` would
    // need to be Hashable too, and equal-by-content isn't what anything
    // here actually needs): required by `.navigationDestination(item:)`
    // in `GroupsListView`, which pushes straight into a freshly-created
    // group and needs `GroupDetail` to satisfy `Hashable`, not just
    // `Identifiable`.
    static func == (lhs: GroupDetail, rhs: GroupDetail) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// This group as the *signed-in caller* sees it — `nil` only if the
    /// caller's own membership is somehow missing from `members` (shouldn't
    /// happen: every route that returns a `GroupDetail` already required the
    /// caller to be a member first), used throughout the new shared
    /// meal-plan/grocery-list screens to decide which actions to even offer
    /// (see `GroupSharedMealPlanView`/`GroupSharedGroceryListView`'s role
    /// gating).
    func myRole(currentUserID: String?) -> GroupRole? {
        guard let currentUserID else { return nil }
        return members.first(where: { $0.id == currentUserID })?.role
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
    /// The recipe's photo, base64-encoded — exactly `Recipe.photoBase64` in
    /// backend/prisma/schema.prisma, `null` for the (overwhelming majority
    /// of) recipes with no user-picked photo. Kept as the raw base64
    /// `String?` here rather than eagerly decoding to `Data?` in a custom
    /// `init(from:)` — same "don't build machinery a plain stored property
    /// already covers" reasoning as `visibility` above, and it means a
    /// malformed/corrupt value from the backend fails only where it's
    /// actually used (`photoData`, decoded on demand) instead of failing
    /// this whole recipe's decode outright. Use `photoData` below to
    /// actually render it — see `RecipeThumbnail`, which already knows how
    /// to turn `Data` into an `Image` for a local `Recipe.photoData`; this
    /// gives the same bytes for a remote one.
    let photoBase64: String?
    let createdAt: Date
    let updatedAt: Date
    let ingredients: [RemoteIngredient]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, instructions, servings, prepMinutes, cookMinutes, visibility, photoBase64, createdAt, updatedAt, ingredients
        case ownerID = "ownerId"
    }

    /// `photoBase64` decoded to raw bytes, ready for `UIImage(data:)` —
    /// `nil` both when there's no photo at all and when the string somehow
    /// isn't valid base64 (shouldn't happen: the backend validates this at
    /// write time — see `photoBase64Field` in routes/recipeLibrary.js — but
    /// decoding defensively here means a corrupt value quietly falls back
    /// to "no photo" instead of crashing or throwing this recipe's whole
    /// decode away over one bad field).
    var photoData: Data? {
        photoBase64.flatMap { Data(base64Encoded: $0) }
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
    /// Same field, same reasoning, as `RemoteRecipe.photoBase64` — see that
    /// property's doc comment. Before this field existed, a shared recipe's
    /// photo never made it across the wire at all — this is the field that
    /// actually fixes the reported bug ("when recipes are shared... it
    /// doesn't show the photo"), specifically for the "Shared" section this
    /// type powers (`RecipesHomeView`/`saveSharedRecipe(_:)`).
    let photoBase64: String?
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
        case title, summary, instructions, servings, prepMinutes, cookMinutes, visibility, photoBase64, createdAt, updatedAt, ingredients, share
        case ownerID = "ownerId"
    }

    /// `photoBase64` decoded to raw bytes — see `RemoteRecipe.photoData`'s
    /// doc comment; same reasoning applies verbatim.
    var photoData: Data? {
        photoBase64.flatMap { Data(base64Encoded: $0) }
    }
}

// MARK: - Group meal planning (Phase 4 — routes/groupMealPlan.js)
//
// These types are the *wire* shapes only — decode targets for
// `AccountsAPIClient`'s new group meal-plan/grocery methods. The local,
// offline-capable store the new shared-plan/shared-list screens actually
// read from lives in SwiftData instead (`GroupPlannedMeal`,
// `GroupMealSuggestion`, `GroupSharedGroceryItem` — see
// `HomeEats/Models/GroupSharedMealPlan.swift` and
// `HomeEats/Models/GroupSharedGroceryItem.swift`); `GroupSyncService` is
// what turns one of these into the other and back.

/// Mirrors the backend's `MealSlot` enum (`BREAKFAST`/`LUNCH`/`DINNER`/
/// `OTHER` — see prisma/schema.prisma) as its own, wire-format-only Swift
/// enum, immediately convertible to/from this app's one *canonical*
/// `MealSlot` type (`HomeEats/Models/MealSlot.swift`) via `localSlot`/
/// `init(localSlot:)` below. A second enum, rather than teaching the local
/// `MealSlot` itself to decode this JSON, on purpose: the local enum's raw
/// values (`"breakfast"`, ...) are its own, unrelated, already-established
/// on-device convention (used nowhere near JSON, only as a SwiftData/
/// `Codable` implementation detail) — decoding `"BREAKFAST"` straight into
/// it would fail outright, and giving it a *second*, custom `Decodable`
/// conformance just for this one caller would mean editing a model this
/// feature's scope deliberately leaves untouched (see `MealSlot.swift`, one
/// of the existing personal-planning models this task's scope notes call
/// out). Every local model in this feature (`GroupPlannedMeal`,
/// `GroupMealSuggestion`) stores the *local* `MealSlot` directly, never this
/// type — it exists purely as a decode/encode step at the network boundary.
enum RemoteMealSlot: String, Codable {
    case breakfast = "BREAKFAST"
    case lunch = "LUNCH"
    case dinner = "DINNER"
    case other = "OTHER"

    var localSlot: MealSlot {
        switch self {
        case .breakfast: return .breakfast
        case .lunch: return .lunch
        case .dinner: return .dinner
        case .other: return .other
        }
    }

    init(localSlot: MealSlot) {
        switch localSlot {
        case .breakfast: self = .breakfast
        case .lunch: self = .lunch
        case .dinner: self = .dinner
        case .other: self = .other
        }
    }
}

/// `GET /groups/:groupId/meal-plan`'s `plannedMeals` rows and
/// `POST .../meal-plan`'s/`.../suggestions/:id/adopt`'s response — exactly
/// `serializePlannedMeal(...)` in routes/groupMealPlan.js. `recipeID` and
/// `restaurantName` are both optional and, per that route's own doc
/// comment, can legitimately both be `nil` at once (the recipe behind a
/// past decision was later deleted by its owner, `onDelete: SetNull`) — see
/// `GroupPlannedMeal.displayTitle` for how that's shown.
struct RemotePlannedMeal: Codable, Identifiable {
    let id: String
    let groupID: String
    let date: Date
    let slot: RemoteMealSlot
    let recipeID: String?
    let restaurantName: String?
    let isOrderIn: Bool
    let decidedByUserID: String
    let decidedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, date, slot, restaurantName, isOrderIn, decidedAt
        case groupID = "groupId"
        case recipeID = "recipeId"
        case decidedByUserID = "decidedByUserId"
    }
}

/// `GET /groups/:groupId/meal-plan`'s `suggestions` rows, and every
/// suggestion-mutating route's response — exactly `serializeSuggestion(...)`
/// in routes/groupMealPlan.js, including the caller-relative `voteCount`/
/// `votedByMe` pair that route's own doc comment explains (a real vote join
/// table under the hood, not a plain counter, specifically so the API can
/// answer "did *I* already vote for this" per suggestion).
struct RemoteMealSuggestion: Codable, Identifiable {
    let id: String
    let groupID: String
    let date: Date
    let slot: RemoteMealSlot
    let recipeID: String?
    let restaurantName: String?
    let isOrderIn: Bool
    let proposedByUserID: String
    let createdAt: Date
    let voteCount: Int
    let votedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, slot, restaurantName, isOrderIn, createdAt, voteCount, votedByMe
        case groupID = "groupId"
        case recipeID = "recipeId"
        case proposedByUserID = "proposedByUserId"
    }
}

/// `GET /groups/:groupId/meal-plan`'s full response shape — every decided
/// meal and every pending suggestion for the group, no date filtering
/// server-side (the client filters locally — see `GroupSyncService`, which
/// pulls this in full every sync rather than paging/filtering by date, same
/// "household-sized data" reasoning the backend route's own doc comment
/// gives for not filtering server-side either).
struct GroupMealPlanResponse: Codable {
    let plannedMeals: [RemotePlannedMeal]
    let suggestions: [RemoteMealSuggestion]
}

// MARK: - Group grocery list (Phase 4 — routes/groupGrocery.js)

/// Mirrors the backend's `GroceryCategory` enum exactly (`PRODUCE`,
/// `DAIRY_AND_EGGS`, ... — see prisma/schema.prisma), converting to/from
/// this app's own local `GroceryCategory` enum (`HomeEats/Models/GroceryCategory.swift`)
/// via `localCategory`/`init(localCategory:)` — same "separate wire-format
/// enum, converted immediately, existing local model left untouched" reasoning
/// as `RemoteMealSlot` above.
enum RemoteGroceryCategory: String, Codable {
    case produce = "PRODUCE"
    case dairyAndEggs = "DAIRY_AND_EGGS"
    case meatAndSeafood = "MEAT_AND_SEAFOOD"
    case bakery = "BAKERY"
    case pantry = "PANTRY"
    case frozen = "FROZEN"
    case beverages = "BEVERAGES"
    case snacks = "SNACKS"
    case household = "HOUSEHOLD"
    case other = "OTHER"

    var localCategory: GroceryCategory {
        switch self {
        case .produce: return .produce
        case .dairyAndEggs: return .dairyAndEggs
        case .meatAndSeafood: return .meatAndSeafood
        case .bakery: return .bakery
        case .pantry: return .pantry
        case .frozen: return .frozen
        case .beverages: return .beverages
        case .snacks: return .snacks
        case .household: return .household
        case .other: return .other
        }
    }

    init(localCategory: GroceryCategory) {
        switch localCategory {
        case .produce: self = .produce
        case .dairyAndEggs: self = .dairyAndEggs
        case .meatAndSeafood: self = .meatAndSeafood
        case .bakery: self = .bakery
        case .pantry: self = .pantry
        case .frozen: self = .frozen
        case .beverages: self = .beverages
        case .snacks: self = .snacks
        case .household: self = .household
        case .other: self = .other
        }
    }
}

/// Mirrors the backend's `GroupGrocerySection` enum (`SUGGESTED`/
/// `THIS_WEEK`/`STAPLES` — see prisma/schema.prisma) directly, as both the
/// wire decode target AND the type the local `GroupSharedGroceryItem` model
/// stores — unlike `MealSlot`/`GroceryCategory`, there's no existing local
/// enum this parallels (the personal-use `GroceryListSection` has a vestigial
/// extra `.rejected` case the backend's own doc comment explicitly says NOT
/// to reintroduce here — see that section's doc comment in
/// prisma/schema.prisma), so one plain, wire-spelled enum is simplest rather
/// than inventing a second local-only one just to mirror an established
/// pattern that doesn't actually apply here.
enum GroupGrocerySection: String, Codable, CaseIterable, Identifiable {
    case suggested = "SUGGESTED"
    case thisWeek = "THIS_WEEK"
    case staples = "STAPLES"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .suggested: return "Suggested"
        case .thisWeek: return "This Week"
        case .staples: return "Staples"
        }
    }
}

/// One row of `GET /groups/:groupId/grocery`'s `items`, and every
/// item-mutating route's response — exactly `serializeItem(...)` in
/// routes/groupGrocery.js.
struct RemoteGroupGroceryItem: Codable, Identifiable {
    let id: String
    let groupID: String
    let name: String
    let category: RemoteGroceryCategory
    let section: GroupGrocerySection
    let quantityText: String
    let isChecked: Bool
    let orderIndex: Double
    /// "My Layout" placement (Phase 4) — mirrors `aisleId`/`aisleManuallySet`
    /// on the backend's `GroupGroceryItem` exactly (see that field's doc
    /// comment in prisma/schema.prisma): while `aisleManuallySet` is
    /// `false`, `aisleID` is not meaningful and a client should fall back to
    /// whichever `RemoteGroupStoreAisle` has `linkedCategory == category` —
    /// this app's `GroupSharedGroceryListView.resolvedAisleID` mirrors that
    /// fallback client-side, the same idea as the personal
    /// `GroceryListView.resolvedAisleID`.
    let aisleID: String?
    let aisleManuallySet: Bool
    let addedByUserID: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, category, section, quantityText, isChecked, orderIndex, createdAt, updatedAt
        case groupID = "groupId"
        case aisleID = "aisleId"
        case aisleManuallySet
        case addedByUserID = "addedByUserId"
    }

    /// Memberwise init with `aisleID`/`aisleManuallySet` defaulted to "not
    /// placed yet" — lets every call site written before Phase 4's "My
    /// Layout" wiring (tests included — see `GroupGroceryItemCreateRaceTests`)
    /// keep compiling unchanged. `Codable`'s synthesized `init(from:)` is a
    /// separate mechanism from this custom init and is unaffected by it —
    /// decoding a real response still requires the backend to send both
    /// fields explicitly, which `serializeItem(...)` always does.
    init(
        id: String, groupID: String, name: String, category: RemoteGroceryCategory, section: GroupGrocerySection,
        quantityText: String, isChecked: Bool, orderIndex: Double,
        aisleID: String? = nil, aisleManuallySet: Bool = false,
        addedByUserID: String, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.category = category
        self.section = section
        self.quantityText = quantityText
        self.isChecked = isChecked
        self.orderIndex = orderIndex
        self.aisleID = aisleID
        self.aisleManuallySet = aisleManuallySet
        self.addedByUserID = addedByUserID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `GET /groups/:groupId/grocery`'s full response shape.
struct GroupGroceryListResponse: Codable {
    let items: [RemoteGroupGroceryItem]
}

// MARK: - Group grocery "My Layout" aisles (Phase 4 iOS wiring — routes/groupGroceryAisles.js)
//
// Wire shapes only, same relationship to the local, offline-capable
// SwiftData layer as the meal-plan/grocery-list types above — see
// `HomeEats/Models/GroupGroceryLayout.swift` for the local mirrors
// (`GroupStoreAisle`, `GroupGroceryHistoryEntry`) and `GroupSyncService` for
// what turns one of these into the other and back. (A third wire type used
// to be declared further down this file, `RemoteGroupStapleItem`/
// `GroupStaplesResponse` — removed along with the rest of the standing
// "staples" template-list feature; see `GroupStoreAisle`'s doc comment for
// the removal note.)

/// One row of `GET .../grocery/aisles`, and every aisle-mutating route's
/// response — exactly `serializeAisle(...)` in routes/groupGroceryAisles.js.
struct RemoteGroupStoreAisle: Codable, Identifiable {
    let id: String
    let groupID: String
    let name: String
    let sortIndex: Double
    /// Set only for the ten starter aisles the backend seeds once per group
    /// (see `ensureDefaultAislesSeeded` in routes/groupGroceryAisles.js) —
    /// same role as the local `StoreAisle.linkedCategory`.
    let linkedCategory: RemoteGroceryCategory?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, sortIndex, linkedCategory, createdAt
        case groupID = "groupId"
    }
}

struct GroupStoreAislesResponse: Codable {
    let aisles: [RemoteGroupStoreAisle]
}

// MARK: - Group grocery history (Phase 4 iOS wiring — GET .../grocery/history in routes/groupGrocery.js)

/// One row of `GET /groups/:groupId/grocery/history` — deliberately smaller
/// than the backend's full `GroupGroceryHistoryEntry` row (no `id`/`groupId`/
/// `normalizedName`): this route is read-only, and nothing on this app's
/// side ever needs to address one row by id — every entry is written
/// automatically, server-side, as a side effect of `PATCH .../grocery/:id`'s
/// `isChecked` transition (see that route's own doc comment), never
/// created/edited/deleted directly by a client — so the response, and this
/// app's local mirror (`GroupGroceryHistoryEntry` in
/// `HomeEats/Models/GroupGroceryLayout.swift`), only carry what's actually
/// rendered.
struct RemoteGroupGroceryHistoryEntry: Codable {
    let name: String
    let category: RemoteGroceryCategory
    let addedAt: Date
}

struct GroupGroceryHistoryResponse: Codable {
    let items: [RemoteGroupGroceryHistoryEntry]
}
