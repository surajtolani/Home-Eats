import Foundation
import UIKit // For `ImageResizing.downsized(...)`'s `CGFloat` parameter — see `RecipeLibraryPayload.init(recipe:)`.

/// Every error `AccountsAPIClient` throws — kept top-level (not nested
/// inside the enum below) to match `ClaudeRecipeServiceError`'s own
/// placement right next to `ClaudeRecipeService` in this codebase, rather
/// than introducing a different convention for this one service.
enum AccountsAPIError: LocalizedError {
    case notConfigured
    case requestFailed
    /// The token was missing, invalid, or expired (a `401` from
    /// `requireAuth` — see backend/middleware/requireAuth.js, which
    /// doesn't distinguish those cases for the caller either). By the time
    /// this is thrown, the stored token has already been cleared and
    /// `AccountSession.signOut()` already called (see
    /// `AccountsAPIClient.sendRaw`) — this case exists so the call site
    /// that triggered it can still show a sensible inline message rather
    /// than a generic one.
    case unauthorized
    /// A `{ "error": "..." }` response the backend sent on purpose — see
    /// every route file under backend/routes/ for the many specific
    /// messages this can carry (already-friends, not-a-member, wrong
    /// verification code, etc.). The message is written to be shown
    /// directly to the user as-is.
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Accounts aren't set up yet."
        case .requestFailed:
            return "Couldn't reach the server. Check your connection and try again."
        case .unauthorized:
            return "You've been signed out. Please sign in again."
        case .server(let message):
            return message
        }
    }
}

/// Talks to the Home Eats backend's accounts/friends/groups/recipe-sharing
/// API (see backend/README.md's "Accounts, friends, and groups" and
/// "Recipe sharing" sections, and every file under `backend/routes/`) — the
/// same deployment `GooglePlacesService`/`ClaudeRecipeService` already
/// point at, just a different, authenticated slice of it. Every method here
/// is `async throws`, mirroring those two services' style; unlike them,
/// most of these calls need a Bearer token (see `authenticated` below),
/// since almost everything past `/auth/*` requires a signed-in user.
enum AccountsAPIClient {
    /// Same backend/deployment as `GooglePlacesService.baseURLString` and
    /// `ClaudeRecipeService.baseURLString` — kept as its own copy rather
    /// than a shared constant because that's the existing pattern in this
    /// codebase (each service owns its own copy of this one string; see
    /// either of those files' own comments on keeping the two in sync by
    /// hand when this ever changes).
    private static let baseURLString = "https://home-eats-uqbp.onrender.com"

    static var isConfigured: Bool { !baseURLString.isEmpty }

    /// A weak back-reference to the app's single `AccountSession`, set once
    /// from `AccountSession.init()`. Why a service reaches "up" into
    /// session state at all, when neither `GooglePlacesService` nor
    /// `ClaudeRecipeService` do anything like this: those two have nothing
    /// to sign out of. Here, a `401` can arrive from literally any
    /// authenticated call, made from any of a dozen different views
    /// (`FriendsListView`, `GroupDetailView`, `RecipeSharePickerSheet`,
    /// ...) — centralizing "a 401 means sign the user out everywhere" in
    /// this one place means every call site just needs to catch and
    /// display `AccountsAPIError`, not *also* remember to call
    /// `accountSession.signOut()` itself. `weak` because this is a
    /// convenience back-channel, not an ownership relationship — the
    /// session object's lifetime is owned by `HomeEatsApp`, not by this
    /// enum.
    static weak var session: AccountSession?

    // MARK: - JSON decoding

    /// Every timestamp this API returns (`createdAt`, `updatedAt`,
    /// `sharedAt`, ...) is a Prisma `DateTime`, which Node's default
    /// `JSON.stringify(Date)` renders as ISO-8601 *with* milliseconds
    /// (`"2024-01-01T12:00:00.000Z"`) — `Foundation`'s plain `.iso8601`
    /// decoding strategy does NOT accept that by default (its formatter
    /// only turns on fractional-seconds support if asked), so decoding
    /// would otherwise fail on every single date field this API returns.
    /// This tries the fractional-seconds formatter first (the actual shape
    /// every response uses) and falls back to the plain one just in case,
    /// rather than assuming one exact format forever. Not `private` so
    /// `HomeEatsTests` can decode fixture JSON with the exact same decoder
    /// this client actually uses, instead of testing a second, possibly-
    /// diverging copy of this configuration.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601WithFractionalSeconds.date(from: string) { return date }
            if let date = iso8601Plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date string, got \"\(string)\"."
            )
        }
        return decoder
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain = ISO8601DateFormatter()

    /// The shape of every non-2xx response this API sends (see every route
    /// file's error responses, and backend/README.md: "Every error response
    /// has the shape `{ "error": "..." }`"). Internal (not `private`) so
    /// `HomeEatsTests` can verify this decodes as expected without needing
    /// a live server.
    struct ServerErrorResponse: Decodable {
        let error: String
    }

    // MARK: - Request plumbing

    /// Runs a request and decodes a JSON body from a 2xx response.
    private static func send<Response: Decodable>(
        _ method: String,
        path: String,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await sendRaw(method, path: path, body: body, authenticated: authenticated)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            // A 2xx response that doesn't decode into what this method
            // expected is this client's bug (a mismatched model), not a
            // condition the user can do anything about — same treatment as
            // a network failure rather than inventing a third error case
            // for it.
            throw AccountsAPIError.requestFailed
        }
    }

    /// Runs a request whose success response has no body worth decoding —
    /// either a real `204 No Content` (every `DELETE` here, see the route
    /// table in backend/README.md) or a 2xx body this client intentionally
    /// doesn't need (e.g. `POST /friends/request` normalizes most of its
    /// success branches to `{ status: "requested" }` on purpose — see its
    /// own doc comment in routes/friends.js on why — but still varies for
    /// the one legitimately-different case, an auto-accept; callers
    /// re-fetch `GET /friends` afterward instead of trying to model any of
    /// that here).
    private static func sendNoContent(
        _ method: String,
        path: String,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws {
        _ = try await sendRaw(method, path: path, body: body, authenticated: authenticated)
    }

    private static func sendRaw(
        _ method: String,
        path: String,
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> Data {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw AccountsAPIError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authenticated {
            guard let token = KeychainTokenStore.readToken() else {
                // No token at all is functionally the same as an expired
                // one from the caller's point of view — either way, the
                // request can't proceed and the user needs to sign in.
                throw AccountsAPIError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountsAPIError.requestFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw AccountsAPIError.requestFailed
        }

        if http.statusCode == 401 {
            // The token this request sent (if any) is no longer good —
            // clear it locally too, so nothing keeps silently retrying with
            // a token the server will never accept again, and flip the
            // app's signed-in state everywhere at once via the `session`
            // back-reference (see its own doc comment above for why this
            // lives here instead of at every individual call site).
            KeychainTokenStore.deleteToken()
            await session?.signOut()
            throw AccountsAPIError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            if let decoded = try? decoder.decode(ServerErrorResponse.self, from: data) {
                throw AccountsAPIError.server(decoded.error)
            }
            throw AccountsAPIError.requestFailed
        }
        return data
    }
}

// MARK: - Auth (POST /auth/request-code, POST /auth/verify-code)

extension AccountsAPIClient {
    /// Starts a Twilio Verify SMS to `phoneNumber` (already normalized to
    /// E.164 — see `PhoneNumberFormatting`). Unauthenticated: this is how a
    /// signed-out user gets a token in the first place.
    static func requestCode(phoneNumber: String) async throws {
        try await sendNoContent(
            "POST", path: "auth/request-code",
            body: ["phoneNumber": phoneNumber],
            authenticated: false
        )
    }

    /// Checks the code Twilio just sent and returns a Bearer token plus the
    /// signed-in `AccountUser` — `AccountSignInView` hands both straight to
    /// `AccountSession.completeSignIn`. Unauthenticated, same reasoning as
    /// `requestCode`.
    static func verifyCode(phoneNumber: String, code: String) async throws -> (token: String, user: AccountUser) {
        struct Response: Decodable {
            let token: String
            let user: AccountUser
        }
        let response: Response = try await send(
            "POST", path: "auth/verify-code",
            body: ["phoneNumber": phoneNumber, "code": code],
            authenticated: false
        )
        return (response.token, response.user)
    }
}

// MARK: - Profile (GET /me, PATCH /me)

extension AccountsAPIClient {
    static func getMe() async throws -> AccountUser {
        struct Response: Decodable { let user: AccountUser }
        let response: Response = try await send("GET", path: "me")
        return response.user
    }

    /// A partial `PATCH /me` — every parameter is independently optional and
    /// only the ones actually passed are sent, matching the backend's own
    /// "omitted key means leave it alone" semantics (see routes/me.js's
    /// `UpdateMeSchema`) rather than always sending every field (which would
    /// silently overwrite anything not passed with whatever stale value the
    /// caller happened to have). Used by `AccountSignInView`'s post-sign-up
    /// profile-completion step (which now saves `displayName`+`firstName`+
    /// `lastName`+`city`+`state`+`country` together, since all five
    /// non-`displayName` fields are collected on that one screen — see that
    /// view's own doc comment) and by `EditProfileView` (any subset of all
    /// six).
    ///
    /// Callable with zero arguments would build an empty `PATCH` body the
    /// backend's own `.refine()` rejects with a 400 — callers are expected
    /// to pass at least one field, same contract the backend documents.
    static func updateProfile(
        displayName: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        city: String? = nil,
        state: String? = nil,
        country: String? = nil
    ) async throws -> AccountUser {
        struct Response: Decodable { let user: AccountUser }
        var body: [String: Any] = [:]
        if let displayName { body["displayName"] = displayName }
        if let firstName { body["firstName"] = firstName }
        if let lastName { body["lastName"] = lastName }
        if let city { body["city"] = city }
        if let state { body["state"] = state }
        if let country { body["country"] = country }
        let response: Response = try await send("PATCH", path: "me", body: body)
        return response.user
    }
}

// MARK: - Friends (POST/GET /friends/*)

extension AccountsAPIClient {
    /// Sends a friend request by phone number, whether or not that number
    /// belongs to an existing user yet (see backend/README.md — a
    /// not-yet-a-user number becomes a standing `Invite` instead). A `409`
    /// ("already friends"/"already pending") surfaces as
    /// `AccountsAPIError.server(...)`, same as any other server-declined
    /// request — `FriendsListView` just shows it inline.
    static func sendFriendRequest(phoneNumber: String) async throws {
        try await sendNoContent("POST", path: "friends/request", body: ["phoneNumber": phoneNumber])
    }

    static func acceptFriendRequest(id friendshipID: String) async throws {
        try await sendNoContent("POST", path: "friends/\(friendshipID)/accept")
    }

    static func declineFriendRequest(id friendshipID: String) async throws {
        try await sendNoContent("POST", path: "friends/\(friendshipID)/decline")
    }

    /// `{ friends, incomingRequests, outgoingRequests }` — see
    /// `FriendsList`'s own doc comment. Friends/groups are never persisted
    /// locally (see `AccountSession`'s doc comment on why) — every screen
    /// that shows them calls straight through to here on appearance.
    static func getFriends() async throws -> FriendsList {
        try await send("GET", path: "friends")
    }
}

// MARK: - Invites (Phase 5 — GET/POST /invites/*)
//
// Mounted at `/invites` — confirmed directly against backend/index.js's
// `app.use("/invites", requireAuth, invitesRouter)`. See `GroupInvite`'s own
// doc comment in AccountModels.swift for what these actually name: a
// **group** Invite addressed to the caller (the "join this group" flow that
// no longer happens instantly even for an already-accepted friend — see
// `inviteToGroup`'s own doc comment below and backend/README.md's "Invites
// and consent" section).

extension AccountsAPIClient {
    /// The caller's own pending group Invites — see `GroupInvite`'s doc
    /// comment. `NotificationsView` gets this same data through
    /// `getNotifications()` instead (its `groupInvites` field is
    /// byte-for-byte this same list per routes/notifications.js's own doc
    /// comment) rather than calling both for one screen; this standalone
    /// method exists for API completeness/symmetry with `getFriends()`, and
    /// is available to any future screen that wants group invites alone
    /// without the friend-request half of the combined feed.
    static func getInvites() async throws -> [GroupInvite] {
        struct Response: Decodable { let invites: [GroupInvite] }
        let response: Response = try await send("GET", path: "invites")
        return response.invites
    }

    /// Recipient only (`403` for anyone else, `409` if not `PENDING`,
    /// `400` for a bare, non-group Invite — see
    /// `loadPendingGroupInviteAsRecipient` in routes/invites.js). Creates
    /// the `GroupMembership` (as `PARTICIPANT`) and marks the Invite
    /// `RESOLVED` server-side, in one transaction. This app doesn't inspect
    /// the `{ invite }` response body (nothing here shows an Invite's raw
    /// status after responding to it), so this is `sendNoContent` rather
    /// than a typed decode, same as `acceptFriendRequest`. Callers must
    /// separately call `ActiveGroupSession.refreshGroups()` afterward if the
    /// newly-joined group needs to show up in the group switcher right away
    /// (see `NotificationsView.respondToGroupInvite`) — this method has no
    /// way to reach that object itself.
    static func acceptInvite(id inviteID: String) async throws {
        try await sendNoContent("POST", path: "invites/\(inviteID)/accept")
    }

    /// Same recipient-only check as accept. Marks the Invite `DECLINED`
    /// (distinct from `CANCELLED` — see the `InviteStatus` doc comment in
    /// prisma/schema.prisma) and grants nothing. A `MANAGER` of the group
    /// can queue a fresh Invite to the same phone number afterward by
    /// calling `inviteToGroup` again — see that method's own "Resend after a
    /// decline" note.
    static func declineInvite(id inviteID: String) async throws {
        try await sendNoContent("POST", path: "invites/\(inviteID)/decline")
    }
}

// MARK: - Notifications (Phase 5, Part 3 — GET /notifications)

extension AccountsAPIClient {
    /// `{ count, friendRequests, groupInvites }` — see `NotificationsFeed`'s
    /// own doc comment for why both lists decode straight into types this
    /// app already has (`IncomingFriendRequest`/`GroupInvite`), with no
    /// separate "notification item" wrapper. `NotificationsSession` is the
    /// one place in this app that calls this method — everything else
    /// (the bell's badge, `NotificationsView`'s list) reads through that
    /// shared object instead of calling this directly, so there's exactly
    /// one in-flight fetch backing both at once rather than two
    /// independently-timed copies of the same feed.
    static func getNotifications() async throws -> NotificationsFeed {
        try await send("GET", path: "notifications")
    }
}

// MARK: - Groups (POST/GET/DELETE /groups/*)

extension AccountsAPIClient {
    /// `memberUserIds` here now goes through the same consent mechanism
    /// `POST /:groupId/invite` (used by `inviteToGroup` below) does — this
    /// route used to create real `GroupMembership` rows for them instantly,
    /// in the same transaction as the group itself, which was a real gap in
    /// Phase 5's own "no path may ever instantly create a GroupMembership
    /// again" guarantee: this route predated, and duplicated, the invite
    /// route's member-adding logic instead of calling it, so it never
    /// picked up that route's rework. Fixed directly in `POST /groups` (see
    /// that route's own doc comment in routes/groups.js): every
    /// `memberUserIds` entry now queues a PENDING `Invite` the same way a
    /// `POST /:groupId/invite` call with that `userId` would, and joins only
    /// once they accept. `CreateGroupView`'s copy no longer distinguishes
    /// the two paths, since they now behave identically.
    static func createGroup(name: String, memberUserIDs: [String] = []) async throws -> GroupDetail {
        struct Response: Decodable { let group: GroupDetail }
        let response: Response = try await send(
            "POST", path: "groups",
            body: ["name": name, "memberUserIds": memberUserIDs]
        )
        return response.group
    }

    /// The lightweight "which groups am I in" list (no member list — see
    /// `getGroup(id:)` for that), matching `GET /groups`'s own doc comment
    /// in backend/README.md.
    static func getGroups() async throws -> [GroupSummary] {
        struct Response: Decodable { let groups: [GroupSummary] }
        let response: Response = try await send("GET", path: "groups")
        return response.groups
    }

    static func getGroup(id groupID: String) async throws -> GroupDetail {
        struct Response: Decodable { let group: GroupDetail }
        let response: Response = try await send("GET", path: "groups/\(groupID)")
        return response.group
    }

    /// Invites an existing friend to the group — **Phase 5: this no longer
    /// adds them directly.** Before Phase 5, `userId` here always created
    /// the `GroupMembership` instantly (an accepted friend had zero chance
    /// to decline); now it always queues/reuses a PENDING `Invite` instead,
    /// exactly like the `phoneNumber` overload just below always has — see
    /// routes/groups.js's own doc comment on `POST /:groupId/invite` for the
    /// full before/after reasoning. This app's response to that change is
    /// entirely UI copy (`InviteToGroupView`'s "From Your Friends" section
    /// now explains it sends an invite, not an instant add) — this method
    /// itself needed no change at all, since it never inspected the
    /// response body either way. (There's a second overload just below for
    /// the by-phone-number path — see its own doc comment for why these are
    /// kept as two overloads rather than one method taking an enum.)
    static func inviteToGroup(groupID: String, userID: String) async throws {
        try await sendNoContent("POST", path: "groups/\(groupID)/invite", body: ["userId": userID])
    }

    /// Invites someone by phone number — queues/reuses a standing `Invite`
    /// for this `groupId` regardless of who the number belongs to (one of
    /// the caller's own accepted friends, a Home Eats user who isn't yet a
    /// friend, or not a user at all), same idea as `sendFriendRequest`. The
    /// backend deliberately reports every one of those outcomes back
    /// identically (see routes/groups.js's own doc comment on
    /// `POST /:groupId/invite`) — this app has no need to tell them apart
    /// either, since it doesn't inspect this call's response body at all.
    /// **Also what a "Resend" action calls** (`GroupDetailView`'s "Pending
    /// Invites" section) for a `DECLINED` invite — see that route's own
    /// "Resend after a decline" doc comment: the "already invited" check
    /// only ever blocks on a still-`PENDING` row, so calling this again
    /// after a decline already works with no separate resend method needed.
    /// Two overloads (`userID:`/`phoneNumber:`) rather than one method
    /// taking `Either<String, String>` or an enum — this mirrors the
    /// backend's own `InviteSchema`, a Zod union of `{ userId }` OR
    /// `{ phoneNumber }` (see routes/groups.js), and reads more plainly at
    /// each call site than an enum wrapper would.
    static func inviteToGroup(groupID: String, phoneNumber: String) async throws {
        try await sendNoContent("POST", path: "groups/\(groupID)/invite", body: ["phoneNumber": phoneNumber])
    }

    /// `MANAGER`-only server-side; a `PARTICIPANT`/non-member calling this
    /// gets a `403` (see routes/groups.js's own doc comment on this route).
    /// No-op-safe if the target is already `MANAGER` — this app's UI
    /// (`GroupDetailView.memberRow`) only ever offers "Promote" for a
    /// `PARTICIPANT` anyway, so that no-op is never actually exercised from
    /// here, but the backend guarantees it regardless. Returns the updated
    /// `GroupMember` — same `publicMember` shape `GET /groups/:groupId`'s
    /// own member list already uses.
    static func promoteMember(groupID: String, userID: String) async throws -> GroupMember {
        struct Response: Decodable { let member: GroupMember }
        let response: Response = try await send("POST", path: "groups/\(groupID)/members/\(userID)/promote")
        return response.member
    }

    /// `MANAGER`-only server-side, same as promote. `409` (surfaced as
    /// `AccountsAPIError.server(...)`) if the target is the group's sole
    /// remaining `MANAGER` and other members would be left behind — the
    /// same `wouldStrandGroup` guard `removeGroupMember` below can also hit
    /// (see routes/groups.js's own doc comment). This app's UI can't
    /// pre-check that client-side without duplicating the backend's own
    /// manager-count query, so `GroupDetailView` just surfaces that `409`'s
    /// message directly through its existing `actionFailure` alert rather
    /// than trying to predict it.
    static func demoteMember(groupID: String, userID: String) async throws -> GroupMember {
        struct Response: Decodable { let member: GroupMember }
        let response: Response = try await send("POST", path: "groups/\(groupID)/members/\(userID)/demote")
        return response.member
    }

    /// `GET /groups/:groupId/invites` — **not part of Phase 5 itself**;
    /// added alongside this iOS-wiring task once it was clear
    /// `getGroup(id:)` carries no invite data at all and a `MANAGER` had no
    /// way to see a group's own outstanding invites for `GroupDetailView`'s
    /// "Pending Invites" section (see `GroupSentInvite`'s own doc comment in
    /// AccountModels.swift, and routes/groups.js's doc comment on this
    /// route, for the full reasoning). `MANAGER`-only server-side; `403` for
    /// a `PARTICIPANT` or non-member. Resending a `DECLINED` invite is just
    /// calling `inviteToGroup(groupID:phoneNumber:)` again with the same
    /// `invitedPhoneNumber` — see that method's own "Resend after a
    /// decline" note; there's no dedicated resend method here either.
    static func getGroupInvites(groupID: String) async throws -> [GroupSentInvite] {
        struct Response: Decodable { let invites: [GroupSentInvite] }
        let response: Response = try await send("GET", path: "groups/\(groupID)/invites")
        return response.invites
    }

    /// Leave (pass your own id) or remove another member. Self-removal is
    /// always allowed; removing another member requires the caller to be a
    /// `MANAGER` of the group (tightened in Phase 3 — a `PARTICIPANT`
    /// attempting it gets a `403` back) — see backend/README.md's "Group
    /// roles" section and routes/groups.js's own doc comment on this route.
    static func removeGroupMember(groupID: String, userID: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/members/\(userID)")
    }
}

// MARK: - Group meal planning (Phase 4 — GET/POST/DELETE /groups/:groupId/meal-plan/*)
//
// Mounted at `/groups/:groupId/meal-plan` — confirmed against
// backend/routes/groupMealPlan.js and backend/README.md's endpoint table.
// Every method here is a thin, typed wrapper the same shape as the Groups
// section above; the actual offline-capable, locally-persisted layer this
// app's new shared-plan screen reads from is `GroupSyncService` +
// `GroupPlannedMeal`/`GroupMealSuggestion` (SwiftData), which call these.

extension AccountsAPIClient {
    /// ISO-8601 (no fractional seconds needed — the backend's
    /// `z.coerce.date()`, used on every `date` field these routes accept,
    /// just calls `new Date(...)`, which parses this fine) for the `date`
    /// field every meal-plan write below sends. One shared helper rather
    /// than formatting inline at each call site, so every write encodes a
    /// date identically.
    static func isoDateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func getGroupMealPlan(groupID: String) async throws -> GroupMealPlanResponse {
        try await send("GET", path: "groups/\(groupID)/meal-plan")
    }

    /// Directly decides a recipe-based meal onto the group's plan —
    /// `MANAGER`-only server-side (see routes/groupMealPlan.js); a
    /// `PARTICIPANT` calling this gets a `403` surfaced the normal way as
    /// `AccountsAPIError.server(...)`. Two overloads (this one, and the
    /// restaurant one just below) rather than one method taking an enum or
    /// two optional parameters — mirrors the backend's own
    /// `MealShapeSchema` "exactly one of recipeId/restaurantName" body shape
    /// (same reasoning as `inviteToGroup`'s two overloads above).
    static func decideGroupMeal(groupID: String, date: Date, slot: MealSlot, recipeID: String) async throws -> RemotePlannedMeal {
        struct Response: Decodable { let plannedMeal: RemotePlannedMeal }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/meal-plan",
            body: ["date": isoDateString(date), "slot": RemoteMealSlot(localSlot: slot).rawValue, "recipeId": recipeID]
        )
        return response.plannedMeal
    }

    static func decideGroupMeal(
        groupID: String, date: Date, slot: MealSlot, restaurantName: String, isOrderIn: Bool
    ) async throws -> RemotePlannedMeal {
        struct Response: Decodable { let plannedMeal: RemotePlannedMeal }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/meal-plan",
            body: [
                "date": isoDateString(date), "slot": RemoteMealSlot(localSlot: slot).rawValue,
                "restaurantName": restaurantName, "isOrderIn": isOrderIn
            ]
        )
        return response.plannedMeal
    }

    /// `MANAGER`-only server-side.
    static func deleteGroupPlannedMeal(groupID: String, id: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/meal-plan/\(id)")
    }

    /// The Participant-facing "propose this for a vote" action — any member,
    /// same recipe-or-restaurant body shape as `decideGroupMeal` above.
    static func suggestGroupMeal(groupID: String, date: Date, slot: MealSlot, recipeID: String) async throws -> RemoteMealSuggestion {
        struct Response: Decodable { let suggestion: RemoteMealSuggestion }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/meal-plan/suggestions",
            body: ["date": isoDateString(date), "slot": RemoteMealSlot(localSlot: slot).rawValue, "recipeId": recipeID]
        )
        return response.suggestion
    }

    static func suggestGroupMeal(
        groupID: String, date: Date, slot: MealSlot, restaurantName: String, isOrderIn: Bool
    ) async throws -> RemoteMealSuggestion {
        struct Response: Decodable { let suggestion: RemoteMealSuggestion }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/meal-plan/suggestions",
            body: [
                "date": isoDateString(date), "slot": RemoteMealSlot(localSlot: slot).rawValue,
                "restaurantName": restaurantName, "isOrderIn": isOrderIn
            ]
        )
        return response.suggestion
    }

    /// Thumbs up/down on a suggestion — any member. Behaves like any real
    /// thumbs-up/down control (see the backend route's own doc comment in
    /// routes/groupMealPlan.js): sending the same `direction` the caller
    /// already voted retracts it; sending the opposite direction switches
    /// it. Returns the updated suggestion (fresh `upvoteCount`/
    /// `downvoteCount`/`myVote`), same as the backend route itself.
    static func voteOnGroupMealSuggestion(groupID: String, suggestionID: String, direction: VoteDirection) async throws -> RemoteMealSuggestion {
        struct Response: Decodable { let suggestion: RemoteMealSuggestion }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/meal-plan/suggestions/\(suggestionID)/vote",
            body: ["direction": direction.rawValue]
        )
        return response.suggestion
    }

    /// `MANAGER`-only. Converts a suggestion into a decided `PlannedMeal`
    /// server-side, in one transaction (see routes/groupMealPlan.js) — this
    /// app deliberately treats it as an immediate, online-only action rather
    /// than something `GroupSyncService` can queue for offline push (see
    /// that service's own doc comment on why).
    static func adoptGroupMealSuggestion(groupID: String, suggestionID: String) async throws -> RemotePlannedMeal {
        struct Response: Decodable { let plannedMeal: RemotePlannedMeal }
        let response: Response = try await send("POST", path: "groups/\(groupID)/meal-plan/suggestions/\(suggestionID)/adopt")
        return response.plannedMeal
    }

    /// `MANAGER`, or the suggestion's own proposer — withdrawing your own
    /// suggestion is allowed even without being a manager (see
    /// routes/groupMealPlan.js's own doc comment on this route).
    static func deleteGroupMealSuggestion(groupID: String, suggestionID: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/meal-plan/suggestions/\(suggestionID)")
    }
}

// MARK: - Group grocery list (Phase 4 — GET/POST/PATCH/DELETE /groups/:groupId/grocery/*)
//
// Mounted at `/groups/:groupId/grocery` — confirmed against
// backend/routes/groupGrocery.js. Same "thin typed wrapper, real local-first
// layer lives in GroupSyncService + GroupSharedGroceryItem" relationship as
// the meal-plan section above.

extension AccountsAPIClient {
    static func getGroupGroceryList(groupID: String) async throws -> GroupGroceryListResponse {
        try await send("GET", path: "groups/\(groupID)/grocery")
    }

    /// Any member may call this, but the backend gates `section`
    /// role-by-role (see routes/groupGrocery.js's own doc comment on
    /// `POST /groups/:groupId/grocery`): a `PARTICIPANT` passing anything
    /// but `.suggested` gets a `403` — this app's role-gated UI is what
    /// keeps a `PARTICIPANT` from ever building that request in the first
    /// place (see `GroupSharedGroceryListView`), same "the UI never offers
    /// an action that would just 403" standard the rest of this feature
    /// holds to.
    static func createGroupGroceryItem(
        groupID: String,
        name: String,
        category: GroceryCategory,
        section: GroupGrocerySection,
        quantityText: String = "",
        quantityCount: Int = 1,
        orderIndex: Double = 0
    ) async throws -> RemoteGroupGroceryItem {
        struct Response: Decodable { let item: RemoteGroupGroceryItem }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/grocery",
            body: [
                "name": name,
                "category": RemoteGroceryCategory(localCategory: category).rawValue,
                "section": section.rawValue,
                "quantityText": quantityText,
                "quantityCount": quantityCount,
                "orderIndex": orderIndex
            ]
        )
        return response.item
    }

    /// `MANAGER`-only. Moves a `SUGGESTED` item to `THIS_WEEK` — the
    /// accept half of the suggest/accept flow. Treated as an immediate,
    /// online-only action by `GroupSyncService`, same reasoning as
    /// `adoptGroupMealSuggestion` above.
    static func acceptGroupGroceryItem(groupID: String, id: String) async throws -> RemoteGroupGroceryItem {
        struct Response: Decodable { let item: RemoteGroupGroceryItem }
        let response: Response = try await send("PATCH", path: "groups/\(groupID)/grocery/\(id)/accept")
        return response.item
    }

    /// General field update. Every parameter is optional and, when `nil`,
    /// simply omitted from the request body (never sent as JSON `null` —
    /// unlike `RecipeLibraryUpdatePayload`, nothing here has a
    /// "leave unchanged" vs. "explicitly clear to null" distinction to make:
    /// every field `UpdateItemSchema` accepts server-side is a plain
    /// optional overwrite, so a plain Swift optional is unambiguous on its
    /// own). Deliberately field-granular at the call site, not just at the
    /// backend: `GroupSyncService`'s offline-queued path only ever calls
    /// this with `isChecked`/`orderIndex`/`quantityCount` (the fields any
    /// member may set — see routes/groupGrocery.js's field-by-field role split), never
    /// with the manager-only fields alongside them, precisely so it can
    /// never accidentally trip the backend's "touching even one
    /// manager-only field rejects the whole request" rule for a
    /// `PARTICIPANT`'s queued checkbox/reorder update.
    static func updateGroupGroceryItem(
        groupID: String,
        id: String,
        name: String? = nil,
        category: GroceryCategory? = nil,
        quantityText: String? = nil,
        section: GroupGrocerySection? = nil,
        isChecked: Bool? = nil,
        orderIndex: Double? = nil,
        quantityCount: Int? = nil,
        // "My Layout" placement (Phase 4) — a real tri-state, not a plain
        // `String?`: `.unchanged` (the default) omits the key entirely,
        // `.set(nil)` sends an explicit JSON `null` ("place this in
        // Unsorted"), `.set(id)` sends a real aisle id. A plain optional
        // can't express "explicitly clear to null" (see `FieldUpdate`'s own
        // doc comment below) — and the distinction matters a lot more here
        // than it looks: sending the `aisleId` key AT ALL, including
        // explicit `null`, always sets `aisleManuallySet: true` server-side
        // (see routes/groupGrocery.js's own doc comment on this route), so
        // an accidental `.set(nil)` where `.unchanged` was meant would
        // silently and permanently opt an item out of its category's
        // default-aisle fallback.
        aisleID: FieldUpdate<String> = .unchanged
    ) async throws -> RemoteGroupGroceryItem {
        struct Response: Decodable { let item: RemoteGroupGroceryItem }
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let category { body["category"] = RemoteGroceryCategory(localCategory: category).rawValue }
        if let quantityText { body["quantityText"] = quantityText }
        if let section { body["section"] = section.rawValue }
        if let isChecked { body["isChecked"] = isChecked }
        if let orderIndex { body["orderIndex"] = orderIndex }
        if let quantityCount { body["quantityCount"] = quantityCount }
        body.setFieldUpdate(aisleID, forKey: "aisleId")
        let response: Response = try await send("PATCH", path: "groups/\(groupID)/grocery/\(id)", body: body)
        return response.item
    }

    /// Allowed-caller rule depends on the item's CURRENT `section` — see
    /// routes/groupGrocery.js's own doc comment on this route; this app's
    /// role-gated UI mirrors that rule when deciding whether to even offer
    /// a delete/reject swipe action in the first place.
    static func deleteGroupGroceryItem(groupID: String, id: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/grocery/\(id)")
    }
}

// MARK: - Group grocery "My Layout" aisles (Phase 4 iOS wiring — GET/POST/PATCH/DELETE /groups/:groupId/grocery/aisles/*)
//
// Mounted at /groups/:groupId/grocery/aisles, BEFORE the more general
// /groups/:groupId/grocery mount — confirmed against
// routes/groupGroceryAisles.js directly. Every route there is open to ANY
// member, not MANAGER-only (see that file's own doc comment for the
// reasoning) — none of these methods take an `isManager` parameter to gate
// on for that reason, unlike some of the Group grocery list section above.

extension AccountsAPIClient {
    /// Also what lazily seeds a group's ten starter aisles the FIRST time
    /// it's ever called for a group with none — see
    /// `ensureDefaultAislesSeeded` in routes/groupGroceryAisles.js and that
    /// file's own doc comment on `GroupStoreAisle` in prisma/schema.prisma.
    /// `GroupSyncService.pull` calls this on every sync cycle (not only when
    /// "My Layout" happens to be on screen), which is what makes the
    /// starter aisles already seeded and synced locally by the time someone
    /// first switches to "My Layout" — flagged explicitly because that
    /// backend doc comment calls this "the one piece of this feature that a
    /// later iOS-wiring task needs to actually call (not just read the
    /// response of)".
    static func getGroupGroceryAisles(groupID: String) async throws -> GroupStoreAislesResponse {
        try await send("GET", path: "groups/\(groupID)/grocery/aisles")
    }

    /// Lands at the end of the group's current walking order server-side —
    /// no `sortIndex` to send (see `POST .../grocery/aisles` in
    /// routes/groupGroceryAisles.js).
    static func createGroupGroceryAisle(groupID: String, name: String) async throws -> RemoteGroupStoreAisle {
        struct Response: Decodable { let aisle: RemoteGroupStoreAisle }
        let response: Response = try await send(
            "POST", path: "groups/\(groupID)/grocery/aisles", body: ["name": name]
        )
        return response.aisle
    }

    /// Rename and/or reposition — every parameter optional and, when `nil`,
    /// simply omitted from the body, same field-granular convention as
    /// `updateGroupGroceryItem` above.
    static func updateGroupGroceryAisle(
        groupID: String, id: String, name: String? = nil, sortIndex: Double? = nil
    ) async throws -> RemoteGroupStoreAisle {
        struct Response: Decodable { let aisle: RemoteGroupStoreAisle }
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let sortIndex { body["sortIndex"] = sortIndex }
        let response: Response = try await send("PATCH", path: "groups/\(groupID)/grocery/aisles/\(id)", body: body)
        return response.aisle
    }

    /// Deleting an aisle any item was manually placed in resets those items
    /// back to falling through to their category's default aisle — handled
    /// entirely server-side in one transaction (see that route's own doc
    /// comment); this app's next pull picks up the reset `aisleId`/
    /// `aisleManuallySet` on any affected item the normal way, no special
    /// handling needed here.
    static func deleteGroupGroceryAisle(groupID: String, id: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/grocery/aisles/\(id)")
    }
}

// MARK: - Group grocery history (Phase 4 iOS wiring — GET /groups/:groupId/grocery/history)
//
// (A third Phase-4 sibling used to be here too: "Group staples"
// GET/POST/PATCH/DELETE /groups/:groupId/grocery/staples/* — removed
// outright, along with the backend route file, Prisma model, and every
// other iOS reference, per direct user feedback that the concept added
// nothing useful. See `GroupStoreAisle`'s doc comment in
// HomeEats/Models/GroupGroceryLayout.swift for the removal note.)

extension AccountsAPIClient {
    /// Read-only — see `RemoteGroupGroceryHistoryEntry`'s own doc comment
    /// for why there's no corresponding create/update/delete method.
    static func getGroupGroceryHistory(groupID: String) async throws -> GroupGroceryHistoryResponse {
        try await send("GET", path: "groups/\(groupID)/grocery/history")
    }
}

// MARK: - Recipe library (POST/GET/PATCH/DELETE /recipe-library/*)
//
// Mounted at `/recipe-library` — confirmed directly against
// backend/index.js's `app.use("/recipe-library", requireAuth, recipeLibraryRouter)`,
// not just backend/README.md's prose, since the README itself notes this
// prefix was still an open question as of Phase 2a's own writing.

extension AccountsAPIClient {
    static func createRecipe(_ payload: RecipeLibraryPayload) async throws -> RemoteRecipe {
        struct Response: Decodable { let recipe: RemoteRecipe }
        let response: Response = try await send("POST", path: "recipe-library", body: payload.asJSONObject())
        return response.recipe
    }

    /// Every recipe the caller owns, any visibility. Not surfaced anywhere
    /// in the UI yet (this app's recipes stay local-first — see
    /// `Recipe.backendRecipeID`'s doc comment — so there's no screen that
    /// needs "all of my recipes as the backend sees them" today), but
    /// implemented for completeness against the full documented API and
    /// ready for whatever cross-device sync story comes after this phase.
    static func getMyRecipes() async throws -> [RemoteRecipe] {
        struct Response: Decodable { let recipes: [RemoteRecipe] }
        let response: Response = try await send("GET", path: "recipe-library/mine")
        return response.recipes
    }

    /// Powers `RecipesHomeView`'s "Shared" section. One entry PER SHARE, not
    /// per recipe — see `SharedRecipeEntry`'s own doc comment on why its
    /// `id` is `share.id`, not the recipe's id.
    static func getSharedRecipes() async throws -> [SharedRecipeEntry] {
        struct Response: Decodable { let recipes: [SharedRecipeEntry] }
        let response: Response = try await send("GET", path: "recipe-library/shared-with-me")
        return response.recipes
    }

    static func getRecipe(id recipeID: String) async throws -> RemoteRecipe {
        struct Response: Decodable { let recipe: RemoteRecipe }
        let response: Response = try await send("GET", path: "recipe-library/\(recipeID)")
        return response.recipe
    }

    /// Partial update — only the fields actually set on `payload` are sent
    /// (see `RecipeLibraryUpdatePayload`'s own doc comment for how it
    /// distinguishes "leave unchanged" from "clear to null").
    static func updateRecipe(id recipeID: String, _ payload: RecipeLibraryUpdatePayload) async throws -> RemoteRecipe {
        struct Response: Decodable { let recipe: RemoteRecipe }
        let response: Response = try await send(
            "PATCH", path: "recipe-library/\(recipeID)",
            body: payload.asJSONObject()
        )
        return response.recipe
    }

    static func deleteRecipe(id recipeID: String) async throws {
        try await sendNoContent("DELETE", path: "recipe-library/\(recipeID)")
    }

    /// Shares with a specific friend. (See the `groupID:` overload just
    /// below — same two-overloads-not-an-enum reasoning as
    /// `inviteToGroup`.)
    static func shareRecipe(id recipeID: String, withUserID userID: String) async throws {
        try await sendNoContent("POST", path: "recipe-library/\(recipeID)/share", body: ["userId": userID])
    }

    static func shareRecipe(id recipeID: String, withGroupID groupID: String) async throws {
        try await sendNoContent("POST", path: "recipe-library/\(recipeID)/share", body: ["groupId": groupID])
    }

    /// Un-shares (owner only). Note this deliberately does NOT flip
    /// visibility back to `PRIVATE` even if it was the last share — see
    /// backend/README.md's "Recipe sharing" section — so a recipe that's
    /// been fully unshared can still show as "Shared" if this app ever
    /// surfaces `visibility` directly; nothing here does yet.
    static func unshareRecipe(id recipeID: String, shareID: String) async throws {
        try await sendNoContent("DELETE", path: "recipe-library/\(recipeID)/share/\(shareID)")
    }
}

// MARK: - Personal restaurant library (routes/restaurants.js, mounted at
// /restaurants/library) — see `RemoteRestaurant`'s own doc comment in
// AccountModels.swift, and `PersonalLibrarySyncService`, for the full story.

extension AccountsAPIClient {
    static func getMyRestaurants() async throws -> [RemoteRestaurant] {
        let response: RestaurantLibraryListResponse = try await send("GET", path: "restaurants/library")
        return response.restaurants
    }

    static func createRestaurant(_ payload: RestaurantLibraryPayload) async throws -> RemoteRestaurant {
        struct Response: Decodable { let restaurant: RemoteRestaurant }
        let response: Response = try await send("POST", path: "restaurants/library", body: payload.asJSONObject())
        return response.restaurant
    }

    /// Always sends every field (never a partial diff) — `PersonalLibrarySyncService`
    /// pushes a restaurant's full current local state on every sync pass
    /// rather than tracking which fields actually changed since the last
    /// push (see that type's own doc comment for why: no multi-writer
    /// conflict story to protect against here, so the simplicity is worth
    /// the redundant bytes for a household-scale library). The backend's
    /// `PATCH .../library/:id` schema still accepts a genuine subset if a
    /// future caller ever wants one — this just doesn't build one.
    static func updateRestaurant(id restaurantID: String, _ payload: RestaurantLibraryPayload) async throws -> RemoteRestaurant {
        struct Response: Decodable { let restaurant: RemoteRestaurant }
        let response: Response = try await send("PATCH", path: "restaurants/library/\(restaurantID)", body: payload.asJSONObject())
        return response.restaurant
    }

    static func deleteRestaurant(id restaurantID: String) async throws {
        try await sendNoContent("DELETE", path: "restaurants/library/\(restaurantID)")
    }
}

/// The request body `POST /restaurants/library` and `PATCH
/// /restaurants/library/:id` both take — same "always send every field"
/// choice `updateRestaurant`'s own doc comment explains, so unlike
/// `RecipeLibraryPayload`/`RecipeLibraryUpdatePayload` this is ONE type for
/// both verbs, not two, and no `FieldUpdate` wrapper for explicit-null vs
/// unchanged: every optional field here is simply sent as whatever the
/// local `Restaurant` currently has, `nil` included, every time.
struct RestaurantLibraryPayload {
    var name: String
    var cuisine: String?
    var priceRange: String?
    var rating: Int?
    var notes: String?
    var websiteUrl: String?
    var address: String?
    var isFavorite: Bool
    var googlePhotoNames: [String]
    var googlePlaceId: String?
    var latitude: Double?
    var longitude: Double?

    init(restaurant: Restaurant) {
        name = restaurant.name
        cuisine = restaurant.cuisine
        priceRange = restaurant.priceRange
        rating = restaurant.rating
        notes = restaurant.notes
        websiteUrl = restaurant.websiteURL
        address = restaurant.address
        isFavorite = restaurant.isFavorite
        googlePhotoNames = restaurant.googlePhotoNames
        googlePlaceId = restaurant.googlePlaceID
        latitude = restaurant.latitude
        longitude = restaurant.longitude
    }

    /// Every optional field sent EXPLICITLY, `NSNull()` standing in for a
    /// Swift `nil` (same established technique as `setFieldUpdate`'s own
    /// doc comment below) rather than the plain `object["key"] = value`
    /// pattern `RecipeLibraryPayload.asJSONObject()` uses elsewhere in this
    /// file — that plain form *omits* the key entirely when `value` is
    /// `nil` (assigning Swift's own `nil` through a `[String: Any]`
    /// subscript removes the key), which is wrong here specifically:
    /// since this type always represents a restaurant's *complete* current
    /// state (never a partial diff — see this struct's own doc comment),
    /// `PATCH`'s handler applies whatever's in the parsed body as-is
    /// (`data: parsed.data`, no per-field `!== undefined` filtering — see
    /// routes/restaurants.js). An omitted key there would silently fail to
    /// clear a field the user removed locally (e.g. cuisine set, then
    /// cleared) instead of actually clearing it on the server — sending an
    /// explicit JSON `null` for every genuinely-nil field is what makes
    /// "always overwrite everything" actually true, for `POST` and `PATCH`
    /// alike.
    func asJSONObject() -> [String: Any] {
        // `.map { $0 as Any } ?? NSNull()` per field, not a bare `?? NSNull()`
        // — `??`'s two sides need to unify to one type, and a `String?`/
        // `Int?`/`Double?` doesn't unify with `NSNull` directly; explicitly
        // erasing to `Any` first (same as `setFieldUpdate` below) is what
        // makes this compile.
        [
            "name": name,
            "isFavorite": isFavorite,
            "googlePhotoNames": googlePhotoNames,
            "cuisine": cuisine.map { $0 as Any } ?? NSNull(),
            "priceRange": priceRange.map { $0 as Any } ?? NSNull(),
            "rating": rating.map { $0 as Any } ?? NSNull(),
            "notes": notes.map { $0 as Any } ?? NSNull(),
            "websiteUrl": websiteUrl.map { $0 as Any } ?? NSNull(),
            "address": address.map { $0 as Any } ?? NSNull(),
            "googlePlaceId": googlePlaceId.map { $0 as Any } ?? NSNull(),
            "latitude": latitude.map { $0 as Any } ?? NSNull(),
            "longitude": longitude.map { $0 as Any } ?? NSNull()
        ]
    }
}

// MARK: - Mapping a local Recipe to the backend's create/update body

/// The request body `POST /recipe-library` and `PATCH /recipe-library/:id`
/// both take (see `CreateRecipeSchema`/`UpdateRecipeSchema` in
/// backend/routes/recipeLibrary.js). A plain struct rather than reusing
/// `RemoteRecipe` for requests too — `RemoteRecipe` models a *response*
/// (it has `id`/`ownerID`/`visibility`/timestamps the caller never sends),
/// and reusing it here would mean either sending fields the backend doesn't
/// accept on the way in or awkwardly making half of `RemoteRecipe` optional
/// just to support both directions.
struct RecipeLibraryPayload {
    var title: String
    var summary: String?
    var ingredients: [RecipeIngredientPayload]
    var instructions: [String]
    var servings: Int?
    var prepMinutes: Int?
    var cookMinutes: Int?
    /// The recipe's photo, base64-encoded — `nil` when the local recipe has
    /// no `photoData` (the overwhelming majority: no photo at all, or a
    /// `.library` recipe's bundled `imageName` asset, which has no bytes to
    /// send in the first place — see `Recipe.photoData`'s own doc comment
    /// on that distinction). Built by `init(recipe:)` below, never set
    /// directly, so it's always already downsized — see that init for why.
    var photoBase64: String?
    /// The recipe's origin page link, and a photo reference that's either a
    /// bundled built-in asset name or a remote image URL — see
    /// `RemoteRecipe.sourceURL`/`.imageName`'s own doc comment for the real
    /// bug this fixes (both used to be silently dropped the moment a
    /// recipe round-tripped through the backend at all).
    var sourceURL: String?
    var imageName: String?

    /// Builds the create/update body straight from a local, on-device
    /// `Recipe` — this is what `RecipeSharePickerSheet` calls the moment a
    /// recipe is shared for the first time (`recipe.backendRecipeID == nil`).
    ///
    /// `photoData` is re-downsized here, right before it's ever sent over
    /// the network, rather than trusted as-is: `RecipeEditorView` already
    /// caps a manually-added photo at 800px on its long edge before it's
    /// even written to `photoData` (and `RecipeAIImportView`'s imported
    /// photos at 1000px), so this is normally a no-op re-encode of an
    /// already-small JPEG — but re-applying the same 800px cap here, right
    /// at the upload boundary, means the backend's own size limit (see
    /// `MAX_PHOTO_BYTES_DECODED` in backend/routes/recipeLibrary.js) is
    /// never at the mercy of some other, future local capture path this
    /// file doesn't know about forgetting to downsize first. Falls back to
    /// the original bytes if `ImageResizing.downsized(...)` can't decode
    /// them as an image at all (shouldn't happen for anything that made it
    /// into `photoData` in the first place, but failing open here — sending
    /// the original rather than silently dropping the photo — means a
    /// decode hiccup costs some upload bandwidth, not the whole photo;
    /// the backend's own size cap still guards against that original being
    /// unreasonably large).
    init(recipe: Recipe) {
        title = recipe.title
        summary = recipe.summary
        ingredients = recipe.ingredients.map {
            RecipeIngredientPayload(name: $0.name, quantity: $0.quantity, unit: $0.unit)
        }
        instructions = recipe.instructions
        servings = recipe.servings
        prepMinutes = recipe.prepMinutes
        cookMinutes = recipe.cookMinutes
        if let photoData = recipe.photoData {
            let uploadData = ImageResizing.downsized(photoData, maxDimension: 800) ?? photoData
            photoBase64 = uploadData.base64EncodedString()
        } else {
            photoBase64 = nil
        }
        sourceURL = recipe.sourceURL
        imageName = recipe.imageName
    }

    /// `[String: Any]` for `JSONSerialization`, matching how
    /// `GooglePlacesService`/`ClaudeRecipeService` already build request
    /// bodies in this codebase (a `Codable` request struct would work too,
    /// but would be the only place in this file mixing decode-only models
    /// with an encodable one, for no real benefit). Optional fields are
    /// *omitted* rather than sent as JSON `null` when `nil` — assigning
    /// `nil` through a `[String: Any]` subscript removes the key entirely —
    /// which matches the backend's Zod schemas exactly: every one of these
    /// fields is `.optional()` with no `.nullable()`, so omitting the key
    /// is the form of "no value" they actually expect (see the schema
    /// comment in backend/routes/recipeLibrary.js on why `.default()` isn't
    /// used there either).
    func asJSONObject() -> [String: Any] {
        var object: [String: Any] = [
            "title": title,
            "ingredients": ingredients.map { $0.asJSONObject() },
            "instructions": instructions
        ]
        object["summary"] = summary
        object["servings"] = servings
        object["prepMinutes"] = prepMinutes
        object["cookMinutes"] = cookMinutes
        object["photoBase64"] = photoBase64
        object["sourceUrl"] = sourceURL
        object["imageName"] = imageName
        return object
    }
}

struct RecipeIngredientPayload {
    var name: String
    var quantity: Double?
    var unit: String?

    func asJSONObject() -> [String: Any] {
        var object: [String: Any] = ["name": name]
        object["quantity"] = quantity
        object["unit"] = unit
        return object
    }
}

// MARK: - Updating a nilable field (PATCH /recipe-library/:id)

/// Distinguishes "leave this field unchanged" from "explicitly clear it to
/// `null`" for one of `RecipeLibraryUpdatePayload`'s nilable fields — a
/// plain `T?` can't express this, because assigning Swift's `nil` through a
/// `[String: Any]` subscript always *removes* the key (see
/// `RecipeLibraryPayload.asJSONObject()`'s doc comment on why that's exactly
/// right for the create path). The backend's `PATCH /recipe-library/:id`
/// handler cares about that distinction, though: an omitted key is left
/// alone, but an explicit JSON `null` clears the field (see
/// `UpdateRecipeSchema` and the `data.summary !== undefined` checks in
/// backend/routes/recipeLibrary.js). `.unchanged` is what every field
/// defaults to below, so building an update only means naming what's
/// actually changing.
enum FieldUpdate<Value> {
    case unchanged
    case set(Value?)
}

/// The request body for `PATCH /recipe-library/:id` — kept as its own type
/// rather than reusing `RecipeLibraryPayload` (the `POST` body), since only
/// an update needs to tell "unchanged" apart from "set to nil"; every field
/// here is optional because `PATCH` accepts any subset (see
/// `UpdateRecipeSchema`). `title`/`ingredients`/`instructions` aren't
/// nullable on the backend (there's no such thing as clearing a recipe's
/// title), so a plain `nil` = "unchanged" is unambiguous for those three;
/// only the genuinely nilable fields (`summary`/`servings`/`prepMinutes`/
/// `cookMinutes`/`photoBase64`) need the `FieldUpdate` wrapper — a recipe's
/// photo can legitimately be cleared (the owner removes it), same as its
/// summary can.
struct RecipeLibraryUpdatePayload {
    var title: String?
    var ingredients: [RecipeIngredientPayload]?
    var instructions: [String]?
    var summary: FieldUpdate<String> = .unchanged
    var servings: FieldUpdate<Int> = .unchanged
    var prepMinutes: FieldUpdate<Int> = .unchanged
    var cookMinutes: FieldUpdate<Int> = .unchanged
    /// `.set(base64String)` to replace the photo, `.set(nil)` to clear it,
    /// `.unchanged` (the default) to leave it alone. Nothing in this app
    /// builds one of these with a photo update yet (no shared-recipe-photo
    /// editing flow exists today — see `RecipeSharePickerSheet`'s doc
    /// comment on the create path being the only wiring done so far), but
    /// it's included for the same "complete against the documented API"
    /// reasoning `getMyRecipes()`'s own doc comment gives.
    var photoBase64: FieldUpdate<String> = .unchanged
    /// Same `FieldUpdate` treatment as `photoBase64` above, for the same
    /// reason — see `RemoteRecipe.sourceURL`/`.imageName`'s doc comment for
    /// what dropping these silently lost. `PersonalLibrarySyncService`
    /// always sends `.set(...)` for both, not `.unchanged` — see that
    /// type's own doc comment on why it always pushes a recipe's full
    /// current state rather than tracking what actually changed.
    var sourceURL: FieldUpdate<String> = .unchanged
    var imageName: FieldUpdate<String> = .unchanged

    func asJSONObject() -> [String: Any] {
        var object: [String: Any] = [:]
        if let title { object["title"] = title }
        if let ingredients { object["ingredients"] = ingredients.map { $0.asJSONObject() } }
        if let instructions { object["instructions"] = instructions }
        object.setFieldUpdate(summary, forKey: "summary")
        object.setFieldUpdate(servings, forKey: "servings")
        object.setFieldUpdate(prepMinutes, forKey: "prepMinutes")
        object.setFieldUpdate(cookMinutes, forKey: "cookMinutes")
        object.setFieldUpdate(sourceURL, forKey: "sourceUrl")
        object.setFieldUpdate(imageName, forKey: "imageName")
        object.setFieldUpdate(photoBase64, forKey: "photoBase64")
        return object
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// `.unchanged` -> key stays absent. `.set(nil)` -> key present with a
    /// JSON `null` (via `NSNull()` — assigning Swift's own `nil` here would
    /// remove the key instead, the exact ambiguity `FieldUpdate` exists to
    /// avoid). `.set(x)` -> key present with `x`.
    mutating func setFieldUpdate<T>(_ update: FieldUpdate<T>, forKey key: String) {
        switch update {
        case .unchanged:
            return
        case .set(let value):
            self[key] = value.map { $0 as Any } ?? NSNull()
        }
    }
}
