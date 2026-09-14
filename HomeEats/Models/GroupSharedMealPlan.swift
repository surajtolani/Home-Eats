import Foundation
import SwiftData

/// Local, offline-capable mirror of one row from a group's shared meal plan
/// on the backend (`GET /groups/:groupId/meal-plan`'s `plannedMeals` — see
/// `backend/routes/groupMealPlan.js`'s `serializePlannedMeal` and
/// `prisma/schema.prisma`'s `PlannedMeal` model, which this mirrors
/// field-for-field). Deliberately a *separate* SwiftData type from the
/// existing local, personal-use `PlannedMeal` model
/// (`HomeEats/Models/PlannedMeal.swift`), even though the two are
/// conceptually parallel — per this feature's scope, that model stays
/// exactly as it is (purely local, per-device, never touching the backend
/// at all), while this one mirrors a group's single shared plan that lives
/// on the backend and every member sees the same rows of. Reuses the
/// *type* `MealSlot` directly (not a duplicate local enum) purely for its
/// existing displayName/symbolName/sortIndex display logic — the backend's
/// own `MealSlot` enum's case names were chosen to match it exactly, case
/// for case (see that enum's doc comment in prisma/schema.prisma), so this
/// app's new group screens get that same visual language for free.
@Model
final class GroupPlannedMeal {
    /// The backend `PlannedMeal.id` once this row has been pushed and
    /// acknowledged — used directly as this model's own unique identifier
    /// rather than a separately-generated local UUID that would then need
    /// reconciling against the server id later. A row created locally and
    /// not yet pushed (`syncState == .pendingCreate`) has no server id yet,
    /// so it's given a temporary placeholder instead (see
    /// `newLocalPlaceholderID()`) that's swapped for the real server id the
    /// moment the push succeeds (`GroupSyncService.push`) — never left in
    /// place alongside a second, separately-inserted "real" row.
    @Attribute(.unique) var id: String
    var groupID: String
    /// Normalized to midnight, local time — same convention as the local
    /// `PlannedMeal.date` (see `PlannedMeal.normalize`), even though the
    /// backend itself does no such normalization on write; keeping it
    /// normalized here too is what lets the new group screens reuse the
    /// exact same day-bucketing helpers (`Date.isSameDay(as:)`) the
    /// personal planner already has.
    var date: Date
    var slot: MealSlot
    /// The backend recipe-library id this meal is based on, if it's a
    /// recipe meal rather than a restaurant one. Exactly one of
    /// `recipeID`/`restaurantName` is ever set by this app — mirrors the
    /// backend's own "exactly one of recipeId/restaurantName" rule (see
    /// `routes/groupMealPlan.js`'s `parseMealShape`) — except for the one
    /// case that route's own doc comment calls out, where a referenced
    /// recipe was later deleted by its owner (`recipeId` cleared
    /// server-side via `onDelete: SetNull`); this app treats that
    /// combination (both `nil`) as "recipe no longer available" for
    /// display, same as the backend's own stated expectation, rather than
    /// crashing on it (see `displayTitle` below).
    var recipeID: String?
    /// A display title for `recipeID`, resolved once
    /// (`GroupSyncService.resolveRecipeTitle`) and cached here so this shows
    /// correctly offline on every subsequent app open without re-fetching —
    /// filled in for free from a matching local `Recipe.backendRecipeID`
    /// when the caller already has that recipe locally (e.g. from the
    /// recipe-sharing feature), or via `GET /recipe-library/:id` otherwise.
    /// `nil` until resolved, or if resolution hasn't succeeded yet (e.g. the
    /// device was offline the first time this row was pulled) — `displayTitle`
    /// falls back to a generic placeholder in that case rather than
    /// assuming this is always populated for a recipe meal.
    var cachedRecipeTitle: String?
    var restaurantName: String?
    var isOrderIn: Bool
    var decidedByUserID: String
    var decidedAt: Date
    /// This row's sync-tracking state — see `GroupSyncState`'s own doc
    /// comment for the full push/pull/reconcile design. Never
    /// `.pendingUpdate` in practice for this particular model: the backend
    /// has no `PATCH` route for a decided meal at all (create-then-delete
    /// only — see routes/groupMealPlan.js), so there's nothing a local edit
    /// could even mean here.
    var syncState: GroupSyncState
    /// The backend has no `updatedAt`/version field on `PlannedMeal` (see
    /// `GroupSyncState`'s own doc comment on why this whole feature is
    /// state-based rather than timestamp-based for exactly this reason);
    /// this just records when this row was last known to match the server
    /// — set on both a successful push and a pull's upsert — for display
    /// purposes, not read by any reconciliation decision.
    var serverUpdatedAt: Date?

    init(
        id: String,
        groupID: String,
        date: Date,
        slot: MealSlot,
        recipeID: String? = nil,
        cachedRecipeTitle: String? = nil,
        restaurantName: String? = nil,
        isOrderIn: Bool = false,
        decidedByUserID: String,
        decidedAt: Date = .now,
        syncState: GroupSyncState = .synced,
        serverUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.date = Self.normalize(date)
        self.slot = slot
        self.recipeID = recipeID
        self.cachedRecipeTitle = cachedRecipeTitle
        self.restaurantName = restaurantName
        self.isOrderIn = isOrderIn
        self.decidedByUserID = decidedByUserID
        self.decidedAt = decidedAt
        self.syncState = syncState
        self.serverUpdatedAt = serverUpdatedAt
    }

    /// Midnight, local time — the one normalization every write path for
    /// this model's `date` must go through (not just `init`), so a row
    /// that's later *updated in place* (`GroupSyncService.reconcilePlannedMeals`'s
    /// upsert path, which sets `existing.date` directly rather than
    /// constructing a fresh instance) stays bucketed onto the same calendar
    /// day as one that's freshly inserted — otherwise a pulled update could
    /// silently leave a row keyed by a raw UTC timestamp instead, which
    /// would still compare equal under `Date.isSameDay(as:)` (a calendar
    /// comparison) but NOT under plain `Date` equality, which is exactly
    /// what `GroupSharedMealPlanView.allDates`'s `Set` dedup relies on to
    /// collapse same-day rows into one section.
    static func normalize(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    var isHomeCooked: Bool { recipeID != nil }
    /// Dining at the restaurant, as opposed to ordering in from it — same
    /// distinction the local `PlannedMeal.isEatingOut` makes.
    var isEatingOut: Bool { restaurantName != nil && !isOrderIn }
    var isOrderingIn: Bool { restaurantName != nil && isOrderIn }

    var displayTitle: String {
        if let cachedRecipeTitle { return cachedRecipeTitle }
        if let restaurantName { return restaurantName }
        // A recipe meal whose title hasn't resolved yet (offline, first
        // pull) still shows *something* distinct from "Planned" so it
        // doesn't look like an empty/broken row, and distinct from the
        // legitimate "recipe was deleted" case (`recipeID == nil` too).
        return recipeID != nil ? "Recipe" : "Planned"
    }

    /// Prefix for a not-yet-synced row's placeholder `id` — see the `id`
    /// doc comment above. Namespaced distinctly enough (not a bare UUID)
    /// that it can never collide with an actual server-generated one.
    static let localPlaceholderIDPrefix = "local-pending-"

    static func newLocalPlaceholderID() -> String {
        localPlaceholderIDPrefix + UUID().uuidString
    }

    var isLocalPlaceholderID: Bool {
        id.hasPrefix(Self.localPlaceholderIDPrefix)
    }
}

/// Local, offline-capable mirror of one row from a group's pending
/// meal-plan suggestions (`GET /groups/:groupId/meal-plan`'s `suggestions`
/// — see `serializeSuggestion` in routes/groupMealPlan.js and
/// `prisma/schema.prisma`'s `MealSuggestion`/`MealSuggestionVote` models).
/// Same "separate type from the existing local, personal-use
/// `MealSuggestion`" reasoning as `GroupPlannedMeal` above.
@Model
final class GroupMealSuggestion {
    /// Same server-id-as-local-id convention as `GroupPlannedMeal.id` — see
    /// its doc comment for the full reasoning, including the
    /// not-yet-pushed placeholder case.
    @Attribute(.unique) var id: String
    var groupID: String
    var date: Date
    var slot: MealSlot
    var recipeID: String?
    /// Same caching idea as `GroupPlannedMeal.cachedRecipeTitle` — see its
    /// doc comment.
    var cachedRecipeTitle: String?
    var restaurantName: String?
    var isOrderIn: Bool
    var proposedByUserID: String
    var createdAt: Date
    /// The *signed-in caller's* own vote on this suggestion — `nil` (no
    /// vote), `.up`, or `.down` — the local mirror of the backend's own
    /// per-viewer `myVote` (see `serializeSuggestion` in
    /// routes/groupMealPlan.js). This is the one field on this model that's
    /// genuinely viewer-relative rather than a plain mirror of a database
    /// column — fine, since this local store only ever represents "what the
    /// signed-in user on this device sees," same as the backend response
    /// it's built from.
    var myVote: VoteDirection?
    /// The backend's own upvote/downvote counts for this suggestion —
    /// mirrored directly since displaying them doesn't need the individual
    /// voter list (see `MealSuggestionVote`'s own doc comment on why the API
    /// itself only ever exposes counts plus `myVote`, never the full voter
    /// list). Two separate counts, not one net score, for the same reason
    /// `serializeSuggestion(...)`'s own doc comment gives: a lone net score
    /// can't tell "nobody's voted" apart from "deeply split."
    var upvoteCount: Int
    var downvoteCount: Int
    /// The last `myVote` value this device actually confirmed with the
    /// server (set on both a successful push and a pull's upsert) — kept
    /// separately from `myVote` itself so a local vote change can be
    /// detected as "needs pushing" (`myVote != lastKnownServerVote`)
    /// without needing a full field-diff mechanism, and so several vote
    /// changes in a row while offline (e.g. vote up, then switch to down,
    /// then un-vote entirely, all before ever syncing) correctly collapse
    /// to whatever single `POST .../vote` call actually reaches the
    /// caller's intended end state, instead of firing the endpoint once per
    /// tap — see `voteLocally(_:)`'s own doc comment, and
    /// `GroupSyncService.pushSuggestions`'s `.pendingUpdate` case, for
    /// exactly how the direction sent to that one call is derived
    /// (`myVote ?? lastKnownServerVote`) so it's correct regardless of how
    /// many local changes led up to it.
    var lastKnownServerVote: VoteDirection?
    /// This row's sync-tracking state. `.pendingUpdate` here specifically
    /// means "the local `myVote` differs from `lastKnownServerVote` and
    /// still needs `POST .../vote` sent" — see that field's own doc comment
    /// above. A suggestion's other fields (date/slot/recipe-or-restaurant)
    /// never change after creation on the backend (there's no `PATCH` route
    /// for one at all — only create, vote, adopt, delete), so a vote change
    /// is the only kind of "update" this row can ever have pending.
    var syncState: GroupSyncState
    var serverUpdatedAt: Date?

    init(
        id: String,
        groupID: String,
        date: Date,
        slot: MealSlot,
        recipeID: String? = nil,
        cachedRecipeTitle: String? = nil,
        restaurantName: String? = nil,
        isOrderIn: Bool = false,
        proposedByUserID: String,
        createdAt: Date = .now,
        myVote: VoteDirection?,
        upvoteCount: Int,
        downvoteCount: Int,
        lastKnownServerVote: VoteDirection? = nil,
        syncState: GroupSyncState = .synced,
        serverUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.date = GroupPlannedMeal.normalize(date)
        self.slot = slot
        self.recipeID = recipeID
        self.cachedRecipeTitle = cachedRecipeTitle
        self.restaurantName = restaurantName
        self.isOrderIn = isOrderIn
        self.proposedByUserID = proposedByUserID
        self.createdAt = createdAt
        self.myVote = myVote
        self.upvoteCount = upvoteCount
        self.downvoteCount = downvoteCount
        // Defaults to `myVote` itself when omitted — the natural "nothing
        // pending yet" starting point for a freshly-created-locally
        // suggestion (the proposer is always auto-voted up, mirroring the
        // backend's own `votes: { create: [{ userId: req.userId, direction:
        // "UP" }] }`), and for a freshly-pulled one (every call site that
        // pulls from the server passes this explicitly as the server's own
        // `myVote` value, so it and `myVote` always agree and nothing looks
        // pending the moment a row is first seen). No call site ever needs
        // `lastKnownServerVote` to genuinely differ from `myVote` while also
        // leaving it unspecified, so a single optional (same defaulting
        // shape this field's prior Bool-typed incarnation,
        // `lastKnownServerVotedByMe`, used) is enough — no need for a
        // doubly-optional parameter just to distinguish "omitted" from
        // "explicitly nil," since those two cases are never actually
        // handled differently here.
        self.lastKnownServerVote = lastKnownServerVote ?? myVote
        self.syncState = syncState
        self.serverUpdatedAt = serverUpdatedAt
    }

    var displayTitle: String {
        if let cachedRecipeTitle { return cachedRecipeTitle }
        if let restaurantName { return restaurantName }
        return recipeID != nil ? "Recipe" : "Suggestion"
    }

    /// Applies a thumbs-up/thumbs-down tap and updates `syncState` to
    /// match — the one mutation this model supports directly (called from
    /// `GroupSharedMealPlanView`'s vote buttons), leaving the actual network
    /// call to `GroupSyncService.push` on the next sync so voting works
    /// instantly offline too. Mirrors the real thumbs-up/down control
    /// behavior `POST .../vote` itself implements (see that route's own
    /// doc comment in routes/groupMealPlan.js): tapping the direction
    /// that's already this suggestion's `myVote` retracts it (`myVote`
    /// becomes `nil`); tapping the other direction sets/switches to it.
    ///
    /// Deliberately never *downgrades* a `.pendingCreate`/`.pendingDelete`
    /// row to `.pendingUpdate`: this row's `id` is still a local placeholder
    /// while `.pendingCreate` (see `isLocalPlaceholderID`), so marking it
    /// `.pendingUpdate` would make `GroupSyncService.pushSuggestions` try to
    /// `POST .../suggestions/:id/vote` against an id the server has never
    /// heard of — a call that can only ever fail, permanently stranding the
    /// row (it would never even attempt the *create* call again, since
    /// `.pendingUpdate` — not `.pendingCreate` — is what it would now be
    /// stuck as). A vote change on a still-`.pendingCreate` row instead just
    /// updates `myVote`/the counts locally and leaves the state alone — the
    /// eventual create call always votes its proposer up automatically
    /// either way (see `POST .../suggestions` in routes/groupMealPlan.js),
    /// so the common case (propose, don't touch your own vote before syncing)
    /// is unaffected; the one edge case this doesn't perfectly capture —
    /// changing your vote on your own suggestion in the same offline stretch
    /// it was created in — just has the vote silently reset to the
    /// auto-applied upvote once the create succeeds, correctable with one
    /// more tap after that, rather than risking the row getting stuck
    /// forever.
    func voteLocally(_ direction: VoteDirection) {
        let previous = myVote
        let next: VoteDirection? = (previous == direction) ? nil : direction
        // Undo the previous vote's contribution, then apply the new one —
        // same two-step shape `serializeSuggestion(...)`'s counts would see
        // across an equivalent pair of server-side writes, so a row that
        // never gets ahead of what a real push-then-pull would compute.
        switch previous {
        case .up: upvoteCount -= 1
        case .down: downvoteCount -= 1
        case nil: break
        }
        switch next {
        case .up: upvoteCount += 1
        case .down: downvoteCount += 1
        case nil: break
        }
        myVote = next
        switch syncState {
        case .synced, .pendingUpdate:
            syncState = myVote == lastKnownServerVote ? .synced : .pendingUpdate
        case .pendingCreate, .pendingDelete:
            break
        }
    }

    static let localPlaceholderIDPrefix = "local-pending-"

    static func newLocalPlaceholderID() -> String {
        localPlaceholderIDPrefix + UUID().uuidString
    }

    var isLocalPlaceholderID: Bool {
        id.hasPrefix(Self.localPlaceholderIDPrefix)
    }
}
