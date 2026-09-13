import Foundation

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
    /// doesn't need (e.g. `POST /friends/request`'s response shape varies —
    /// `{ invite }`, `{ friendship }`, or `{ friendship, autoAccepted }` —
    /// depending on which of several branches the backend took; callers
    /// re-fetch `GET /friends` afterward instead of trying to model all
    /// three).
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

    /// Sets the caller's display name — used once by the post-sign-in name
    /// prompt (`AccountSignInView`), and available for a future profile
    /// editor.
    static func updateDisplayName(_ displayName: String) async throws -> AccountUser {
        struct Response: Decodable { let user: AccountUser }
        let response: Response = try await send(
            "PATCH", path: "me",
            body: ["displayName": displayName]
        )
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

// MARK: - Groups (POST/GET/DELETE /groups/*)

extension AccountsAPIClient {
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

    /// Adds an existing friend to the group directly. (There's a second
    /// overload just below for the by-phone-number path — see its own doc
    /// comment for why these are kept as two overloads rather than one
    /// method taking an enum.)
    static func inviteToGroup(groupID: String, userID: String) async throws {
        try await sendNoContent("POST", path: "groups/\(groupID)/invite", body: ["userId": userID])
    }

    /// Invites someone by phone number — an existing user (added directly,
    /// same anti-stranger accepted-friend rule as the `userID` overload) or
    /// not yet a user (queued as a standing `Invite`, same idea as
    /// `sendFriendRequest`). Two overloads (`userID:`/`phoneNumber:`)
    /// rather than one method taking `Either<String, String>` or an enum —
    /// this mirrors the backend's own `InviteSchema`, a Zod union of
    /// `{ userId }` OR `{ phoneNumber }` (see routes/groups.js), and reads
    /// more plainly at each call site than an enum wrapper would.
    static func inviteToGroup(groupID: String, phoneNumber: String) async throws {
        try await sendNoContent("POST", path: "groups/\(groupID)/invite", body: ["phoneNumber": phoneNumber])
    }

    /// Leave (pass your own id) or remove another member — v1 has no admin
    /// role, so any current member can remove any other (see
    /// backend/README.md's note on `DELETE /groups/:groupId/members/:userId`).
    static func removeGroupMember(groupID: String, userID: String) async throws {
        try await sendNoContent("DELETE", path: "groups/\(groupID)/members/\(userID)")
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

    /// Full replace of every field `payload` sets — this client always
    /// builds a complete `RecipeLibraryPayload` from a local `Recipe` (see
    /// `RecipeLibraryPayload.init(recipe:)`), so it never needs the
    /// backend's "omitted field = unchanged" partial-update behavior in
    /// practice, even though the route itself supports it.
    static func updateRecipe(id recipeID: String, _ payload: RecipeLibraryPayload) async throws -> RemoteRecipe {
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

    /// Builds the create/update body straight from a local, on-device
    /// `Recipe` — this is what `RecipeSharePickerSheet` calls the moment a
    /// recipe is shared for the first time (`recipe.backendRecipeID == nil`).
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
