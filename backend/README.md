# Home Eats backend

An Express server with two jobs. First, a proxy in front of the Google
Places API and the Claude API, so the real API keys live only here (as
environment variables) and never ship inside the iOS app — see
`GooglePlacesService.swift` and `ClaudeRecipeService.swift` in the iOS app
for the client side of that. Second — new as of this feature — the real
backend for accounts, friends, and groups: phone number + SMS sign-in, a
friends list, and Splitwise-style groups, backed by Postgres — and, new as
of Phase 2a, recipe sharing on top of that same layer. Phase 3 adds a
MANAGER/PARTICIPANT role to group membership, plus a group's single shared
meal plan and shared grocery list built on top of it. See "Accounts,
friends, and groups", "Recipe sharing", "Group meal planning", and "Group
grocery list" below.

## 1. Get a Google Places API key

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and
   create a new project (or reuse one).
2. **APIs & Services → Library** → search for and enable **"Places API
   (New)"**. Also search for and enable **"Geocoding API"** — used by
   `/restaurants/search-natural` (see below) to turn a place named in a
   sentence ("near Greenwich") into coordinates; skip it if you don't plan
   to use that feature, everything else here works without it.
3. **Billing** → attach a billing account. Google requires this even for
   free-tier usage — new accounts get recurring free monthly credit, but a
   card must be on file. Set a budget alert here too, so you notice if
   usage ever spikes unexpectedly.
4. **APIs & Services → Credentials → Create Credentials → API key.**
5. **Restrict the key**: click into it, under "API restrictions" choose
   "Restrict key" and select "Places API (New)" and "Geocoding API" (only
   the ones you actually enabled above). Since this key lives on your
   server (not the app), you do *not* need an iOS bundle ID restriction
   here — restrict by API only.

## 1b. Get a Claude API key

1. Go to [console.anthropic.com](https://console.anthropic.com) → API Keys
   → Create Key. (If you already have one from the PlanAway backend, you
   can reuse the same Anthropic account/organization — just create a
   separate key here so the two apps' usage is billed/tracked separately.)
2. Add credit / a billing method under **Settings → Billing** if you
   haven't already — same "billing required" story as Google.

## 1c. Set up accounts (Postgres + Twilio Verify + JWT)

This backend is no longer just a stateless proxy — it's now the source of
truth for accounts, friends, and groups (see "Accounts, friends, and
groups" below for the full picture). That needs three more things:

**A Postgres database.** Any standard Postgres works — Render Postgres,
[Railway](https://railway.app), [Supabase](https://supabase.com), or your
own; nothing here is tied to one provider. Whatever you use, you end up
with a connection string that looks like
`postgresql://user:password@host:5432/dbname?schema=public` — that's your
`DATABASE_URL`.

Once you have `DATABASE_URL` set (in `.env` locally, or as a real
environment variable in production — see below), apply the schema:

```bash
cd backend
npx prisma generate
npx prisma migrate deploy
```

This creates every table in `prisma/schema.prisma` (`User`, `Friendship`,
`Group`, `GroupMembership`, `Invite`, `Recipe`, `RecipeIngredient`,
`RecipeShare`, `PlannedMeal`, `MealSuggestion`, `MealSuggestionVote`,
`GroupGroceryItem`). Run it again after pulling any future change to
`prisma/schema.prisma`/`prisma/migrations/` — it's safe to run repeatedly, it
only applies migrations that haven't run yet. (`prisma migrate dev` also
works locally if you want an interactive flow that can generate new
migrations as the schema evolves; `migrate deploy` is the non-interactive
one to use in production and in this initial setup.)

Note on the `prisma`/`@prisma/client` version pin in `package.json`: at the
time this was built, Prisma's newest major version (7) had removed the
ability to put a `url` directly in `schema.prisma` and instead requires
wiring up an explicit database driver adapter in code just to connect —
more moving parts than this project needs. Both packages are pinned to
`6.19.3` (a fully-supported prior major, not an abandoned one) to keep the
simple `DATABASE_URL`-in-the-environment model described here. If you
intentionally want to move to Prisma 7+ later, that's a deliberate
migration, not a drop-in version bump.

**A Twilio Verify service**, for sending/checking SMS codes:

1. Create a [Twilio](https://www.twilio.com) account (or use an existing
   one) and grab your **Account SID** and **Auth Token** from the Twilio
   Console dashboard — these become `TWILIO_ACCOUNT_SID` and
   `TWILIO_AUTH_TOKEN`.
2. In the Console, go to **Verify → Services → Create new Service**. Give it
   a name (e.g. "Home Eats"). Copy its **Service SID** (starts with `VA`) —
   this becomes `TWILIO_VERIFY_SERVICE_SID`.
3. That's it — no per-number setup needed. Verify handles sending the code,
   checking it, expiry, and rate-limiting on its own; this backend just
   calls its API (see `lib/twilio.js` and `routes/auth.js`).
4. Trial Twilio accounts can only send SMS to phone numbers you've
   pre-verified in the Console under **Phone Numbers → Verified Caller
   IDs** — fine for your own testing, but real users will need a paid
   account before `POST /auth/request-code` works for their number.

**A JWT signing secret**: any long random string works as
`JWT_SECRET` — e.g. generate one with `openssl rand -hex 32`. This signs
the tokens issued by `POST /auth/verify-code`; anyone who has it can mint
valid tokens for any user id, so treat it like any other secret (env var
only, never committed).

## 2. Run it locally

```bash
cd backend
cp .env.example .env
# edit .env: paste in GOOGLE_PLACES_API_KEY, ANTHROPIC_API_KEY, DATABASE_URL,
# TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_VERIFY_SERVICE_SID, JWT_SECRET
npm install
npx prisma generate         # regenerates the Prisma Client from the current schema
npx prisma migrate deploy   # creates the accounts/friends/groups tables
npm start
```

The server calls `prisma.$connect()` before it starts listening, so it will
refuse to start at all without a reachable `DATABASE_URL` — even if you
only care about the restaurant/recipe routes above.

Check it's working:

```bash
curl "http://localhost:4000/health"
curl "http://localhost:4000/restaurants/search?q=pizza+near+me"
curl -X POST "http://localhost:4000/restaurants/search-natural" \
  -H "Content-Type: application/json" \
  -d '{"query": "casual pizza place near Greenwich"}'
curl -X POST "http://localhost:4000/recipes/extract" \
  -H "Content-Type: application/json" \
  -d '{"notesText": "Grandma'\''s pancakes: 2 cups flour, 2 eggs, 1.5 cups milk. Mix and cook on a griddle."}'
curl -X POST "http://localhost:4000/recipes/recommend" \
  -H "Content-Type: application/json" \
  -d '{"ingredients": ["chicken thighs", "rice", "broccoli"]}'

# Accounts: request a code, verify it, then call an authenticated route
curl -X POST "http://localhost:4000/auth/request-code" \
  -H "Content-Type: application/json" \
  -d '{"phoneNumber": "+14155551234"}'
curl -X POST "http://localhost:4000/auth/verify-code" \
  -H "Content-Type: application/json" \
  -d '{"phoneNumber": "+14155551234", "code": "123456"}'
# ^ copy the "token" from that response's JSON for the next call
curl "http://localhost:4000/me" -H "Authorization: Bearer <token>"

# Recipe sharing: create a recipe, then list "my recipes"
curl -X POST "http://localhost:4000/recipe-library" \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"title": "Weeknight Chili", "ingredients": [{"name": "ground beef", "quantity": 1, "unit": "lb"}], "instructions": ["Brown the beef.", "Add spices and simmer."]}'
curl "http://localhost:4000/recipe-library/mine" -H "Authorization: Bearer <token>"
```

## 3. Deploy it (Render, same as the pattern used elsewhere)

1. [render.com](https://render.com) → New → Web Service → connect this
   GitHub repo.
2. **Root Directory**: `backend`
3. **Build Command**: `npm install && npx prisma generate && npx prisma migrate deploy`
   — `migrate deploy` applies any not-yet-applied migrations so the
   *database* schema matches the code being deployed, but it does NOT
   regenerate the Prisma *Client* (the actual JS code `require("@prisma/
   client")` returns) — that's a separate step, `prisma generate`, and
   `npm install` only re-triggers it when `package.json`'s dependencies
   actually changed, not just because `schema.prisma` did. Skipping the
   explicit `prisma generate` here is exactly what caused a real
   production bug once: the server kept running against a stale,
   previously-generated Client that didn't know about a field
   (`GroupMembership.role`) a newer `schema.prisma`/route had already
   added, throwing `PrismaClientValidationError: Unknown argument`
   on every request that touched it — even though the migration itself
   had applied fine and the column really did exist in the database.
   (Render Postgres works fine here; so does any external Postgres
   reachable from Render.)
4. **Start Command**: `npm start`
5. **Environment** → add `GOOGLE_PLACES_API_KEY`, `ANTHROPIC_API_KEY`,
   `DATABASE_URL`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
   `TWILIO_VERIFY_SERVICE_SID`, and `JWT_SECRET` — see "Set up accounts"
   above for where the Twilio/JWT values come from, and Render's own
   Postgres add-on (or your external provider) for `DATABASE_URL`. Do not
   put any of these anywhere in the repo — environment variables are the
   only place they should live.
6. Deploy. Render gives you a URL like `https://home-eats-backend.onrender.com`.

## 4. Point the iOS app at it

Open `HomeEats/Services/GooglePlacesService.swift` and
`HomeEats/Services/ClaudeRecipeService.swift` and replace each file's
`baseURLString` placeholder with your deployed Render URL (both files point
at the same backend — one constant each, so it's easy to keep them in
sync). That's the only change needed on the app side:

- `RestaurantListView`'s search automatically starts using Google's richer
  results (rating, price, cuisine) instead of falling back to Apple's free
  MapKit search, which can't provide any of those three.
- The ✨ button next to search opens "Ask for a Restaurant" — a free-text,
  natural-language search ("casual pizza near Greenwich"), backed by both
  Claude and Google Places together. Needs both keys configured; if either
  is missing, that button is disabled instead of half-working.
- Recipes gets a "From a Photo or Notes" import option and a "Recommend a
  Meal" screen, both backed by Claude.

## 5. Accounts, friends, and groups

Phase 1 of turning Home Eats into a real multi-person app: accounts (phone
number + SMS code, so it isn't tied to Apple/iOS), a personal friends list,
and groups built from that list — modeled after Splitwise, right down to a
person being able to belong to several groups at once (a "household" and a
separate "our Peru trip" group, say). See `prisma/schema.prisma` for the
full data model and the reasoning behind each table. As of Phase 3
(`ae15dcd` and the fix round after it), the iOS app calls all of this:
`FriendsListView` (friends list, requests, add-by-phone) and
`GroupsListView`/`GroupDetailView` (groups, members, invites) are its main
screens for it — see `HomeEats/Services/AccountsAPIClient.swift` for the
full client.

**Invites and consent.** An `Invite` (someone added by phone number who
either isn't a Home Eats user yet, or is one but not yet an accepted friend
of the inviter) never grants anything by itself. It resolves into an
ordinary incoming friend request — the same `PENDING` `Friendship` row, and
the same `GET /friends`'s `incomingRequests` entry, as a friend request sent
directly — that the invited person has to explicitly accept via
`POST /friends/:friendshipId/accept` like any other. An invite that also
named a `groupId` (from `POST /groups/:groupId/invite`) only grants that
`GroupMembership` at the moment that specific friend request is accepted,
never before — see the `Invite` model's doc comment in
`prisma/schema.prisma` and `resolveInvitesForAcceptedFriendship` in
`routes/friends.js` for exactly how that resolution works, including its one
known limitation (it only fires when the original inviter also ends up as
that friendship's requester — see that function's own doc comment).
Declining the friend request cancels any tied invite(s) instead
(`cancelInvitesForDeclinedFriendship`) rather than leaving them `PENDING`
forever.

**Group roles (Phase 3).** Every `GroupMembership` now carries a `role`:
`MANAGER` or `PARTICIPANT` — a two-tier permission model, not the
free-for-all every-member-is-equal v1 group membership had before this
phase. A group's creator starts `MANAGER`; anyone added afterwards — via
`memberUserIds` on `POST /groups`, or via `POST /groups/:groupId/invite`
(direct or by-phone) — starts `PARTICIPANT`. Existing groups from before
this phase were backfilled the same way: the membership row matching
`group.createdByUserId` became `MANAGER`, every other membership became
`PARTICIPANT` — and since `createdByUserId` is nullable (see the note on it
further down), a group whose creator's account was already deleted by the
time of the backfill has no way to know who to promote, so every one of its
memberships was simply left `PARTICIPANT`. See the `GroupRole`/
`GroupMembership` doc comments in `prisma/schema.prisma` for the full
reasoning, and its migration
(`prisma/migrations/20260913020000_group_roles_meal_plan_grocery`) for the
exact backfill.

Roles tighten group-*management* itself: `POST /groups/:groupId/invite` is
now `MANAGER`-only (a `PARTICIPANT` gets `403`), and
`DELETE /groups/:groupId/members/:userId` removing someone else is now
`MANAGER`-only too — but removing *yourself* (leaving) still works
regardless of role, at any time, for anyone. `GET /groups/:groupId`'s
member list includes each member's `role` so a client can show/gate on it
without a second request. There's deliberately no promote/demote-role
endpoint yet — a reasonable follow-up once real usage shows it's needed,
out of scope for this phase. Roles also gate the group meal-plan and
grocery-list routes below, with their own (different, more field-grained in
grocery's case) rules — see "Group meal planning" and "Group grocery list".

**Phone-number privacy.** `POST /friends/request` and
`POST /groups/:groupId/invite` both report success back the same way
(`{ "status": "requested" }` / `{ "status": "invited" }`, both `201`)
whether the phone number given belongs to a registered user or not —
otherwise the response shape/status would double as a way to check which
phone numbers are Home Eats users, without any actual relationship to the
caller required. Genuinely different outcomes the caller already has a
legitimate reason to know about (already friends, already a group member,
already invited, adding one of your own accepted friends by `userId` or by
their phone number) still report back distinctly.

Every route below except the two `/auth/*` ones requires
`Authorization: Bearer <token>` (the token `POST /auth/verify-code`
returns). A missing/invalid/expired token gets a `401`. Every error
response has the shape `{ "error": "..." }`.

| Method | Path | Auth | Body | Notes |
|---|---|---|---|---|
| POST | `/auth/request-code` | none | `{ phoneNumber }` | Sends an SMS code via Twilio Verify. `phoneNumber` must be E.164 (e.g. `+14155551234`). Rate-limited (see "Rate limiting" below); `429` if exceeded. |
| POST | `/auth/verify-code` | none | `{ phoneNumber, code }` | Checks the code; finds-or-creates the `User`, turns any pending `Invite`s for that number into ordinary `PENDING` friend requests (see "Invites and consent" above — this does **not** auto-accept a friendship or auto-join a group), and returns `{ token, user }`. |
| GET | `/me` | required | — | Returns `{ user: { id, phoneNumber, displayName, firstName, lastName, city, country, createdAt } }` for the caller. |
| PATCH | `/me` | required | `{ displayName?, firstName?, lastName?, city?, country? }` | Partial update — any subset of these fields, all independently optional; omitted keys are left alone. Each provided field must be non-empty (`400` otherwise — none of these are meant to be clearable back to `null` once set). `400` if the body has none of these keys at all. Returns the updated `{ user }` in the same shape as `GET /me`. |
| POST | `/friends/request` | required | `{ phoneNumber }` | Sends a friend request. If that number belongs to an existing user with no prior relationship, creates a `PENDING` `Friendship`; if a request in the other direction was already pending, this accepts it instead (`200`, `{ friendship, autoAccepted: true }`). If the number isn't a user yet, creates an `Invite` (no group). The first two of those report back identically — `201`, `{ "status": "requested" }` — see "Phone-number privacy" above. `409` if already friends, already pending, or already invited. |
| POST | `/friends/:friendshipId/accept` | required | — | Recipient only; `403` otherwise, `409` if not `PENDING`. Also resolves any tied `Invite`(s) into `GroupMembership` — see "Invites and consent" above. |
| POST | `/friends/:friendshipId/decline` | required | — | Recipient only; same error shape as accept. Also cancels any tied `Invite`(s) (see "Invites and consent" above). |
| GET | `/friends` | required | — | `{ friends: [...], incomingRequests: [...], outgoingRequests: [...] }` — accepted friends, plus separate pending lists for requests you've received and sent. |
| POST | `/groups` | required | `{ name, memberUserIds?: string[] }` | Creates a group with the caller as a member (their own membership starts `MANAGER`), plus any `memberUserIds` (each starts `PARTICIPANT`) — each must already be an accepted friend of the caller (`400` otherwise, so you can't add a stranger's id). `memberUserIds` is capped at 100 entries (`400` if exceeded). Returns `{ group }` including the member list with roles. |
| GET | `/groups` | required | — | `{ groups: [...] }` — every group the caller belongs to (a lightweight list; use the next route for members/roles). |
| GET | `/groups/:groupId` | required | — | `{ group }` with the full member list (each entry includes `role`), phone numbers included (safe here — everyone returned is a fellow member of this same group). `403` if the caller isn't a member. |
| POST | `/groups/:groupId/invite` | **MANAGER only** | `{ userId }` **or** `{ phoneNumber }` | A member who isn't a `MANAGER` gets `403` (see "Group roles" above); a non-member also gets `403`. `userId`, or a `phoneNumber` that matches one of the caller's own accepted friends, is added as a member directly, starting `PARTICIPANT` (`201`, `{ member }`). Any other `phoneNumber` — a Home Eats user who isn't yet an accepted friend of the caller, or not a user at all — queues an `Invite` with this `groupId` (and, if that phone number is already a user with no prior relationship to the caller, also sends them an ordinary friend request) and reports back identically either way (`201`, `{ "status": "invited" }`) — see "Phone-number privacy" above. `409` if already a member / already invited. |
| DELETE | `/groups/:groupId/members/:userId` | required (self always allowed; **MANAGER** for anyone else) | — | Leave (pass your own id) — always allowed for any member, regardless of role. Removing someone ELSE's membership is `MANAGER`-only (`403` for a `PARTICIPANT` trying to remove another member). `403` if the caller isn't a member at all, `404` if the target isn't a member. |
| POST | `/recipe-library` | required | `{ title, summary?, ingredients: [{ name, quantity?, unit? }], instructions: string[], servings?, prepMinutes?, cookMinutes? }` | Creates a recipe owned by the caller, starting `PRIVATE`. `ingredients`/`instructions` are each capped at 200 entries (`400` if exceeded). Returns `{ recipe }` including its ingredients. |
| GET | `/recipe-library/mine` | required | — | `{ recipes: [...] }` — every recipe the caller owns, any visibility. |
| GET | `/recipe-library/shared-with-me` | required | — | `{ recipes: [...] }` — every recipe shared directly with the caller, or via any group they belong to. One entry per share (a recipe shared with you two ways appears twice); each entry carries a `share: { sharedAt, sharedBy, sharedWithGroup }` so the UI can show who shared it / via which group. |
| GET | `/recipe-library/:recipeId` | required | — | `{ recipe }` with full ingredient detail. `403` unless the caller is the owner, a direct share target, or a member of a group it's shared with; `404` if it doesn't exist. |
| PATCH | `/recipe-library/:recipeId` | required | Any subset of the POST body's fields | Owner only (`403` otherwise). Omitted fields are left unchanged; an included `ingredients` array wholesale-replaces the recipe's ingredient list (delete-and-recreate, not diffed/patched row-by-row). |
| DELETE | `/recipe-library/:recipeId` | required | — | Owner only (`403` otherwise). Cascades to its ingredients and shares. |
| POST | `/recipe-library/:recipeId/share` | required | `{ userId }` **or** `{ groupId }` | Owner only — sharing further isn't delegated to someone it's already shared with. `userId` must be an accepted friend of the owner; `groupId` must be a group the owner belongs to (`400` otherwise, same anti-stranger rule as `/groups`). Flips visibility `PRIVATE` → `SHARED` if needed. `409` if already shared with that exact user/group. |
| DELETE | `/recipe-library/:recipeId/share/:shareId` | required | — | Un-share, owner only (`403` otherwise). Does **not** revert visibility back to `PRIVATE` even if it was the last share — see "Recipe sharing" below. |
| GET | `/groups/:groupId/meal-plan` | required (member) | — | `{ plannedMeals: [...], suggestions: [...] }` — every decided meal and every pending suggestion for the group, no date filtering server-side (client filters locally). Each suggestion includes `voteCount` and `votedByMe` (whether the caller has voted for it). `403` if the caller isn't a member. |
| POST | `/groups/:groupId/meal-plan` | **MANAGER only** | `{ date, slot, recipeId }` **or** `{ date, slot, restaurantName, isOrderIn? }` | Directly decides a meal (created already-decided, not a suggestion). `slot` is one of `BREAKFAST`/`LUNCH`/`DINNER`/`OTHER`. Exactly one of `recipeId`/`restaurantName` (`400` otherwise); `recipeId` must reference a recipe that already exists in `/recipe-library` **and** is visible to the caller — owner, a direct share, or a shared group (`400` otherwise). `403` for a `PARTICIPANT`. |
| DELETE | `/groups/:groupId/meal-plan/:id` | **MANAGER only** | — | `403` for a `PARTICIPANT`, `404` if the planned meal doesn't belong to this group. |
| POST | `/groups/:groupId/meal-plan/suggestions` | required (any member) | Same body shape as `POST /groups/:groupId/meal-plan` | The Participant-facing "suggest a recipe/restaurant/order-in for a vote" action. The proposer is automatically counted as having voted for their own suggestion. |
| POST | `/groups/:groupId/meal-plan/suggestions/:id/vote` | required (any member) | — | Toggles the caller's own vote on/off (an existing vote is removed; no vote is added). Returns the updated `{ suggestion }` with `voteCount`/`votedByMe`. |
| POST | `/groups/:groupId/meal-plan/suggestions/:id/adopt` | **MANAGER only** | — | Converts the suggestion into a decided `PlannedMeal` (same date/slot/recipe-or-restaurant) and deletes the suggestion, in one transaction. `403` for a `PARTICIPANT`. |
| DELETE | `/groups/:groupId/meal-plan/suggestions/:id` | **MANAGER, or the suggestion's own proposer** | — | Lets you withdraw your own suggestion even without being a manager (mirrors the local app's own suggestion-withdrawal pattern); anyone else gets `403`. |
| GET | `/groups/:groupId/grocery` | required (member) | — | `{ items: [...] }` — every item on the group's shared list; client groups/filters by category/section locally. |
| POST | `/groups/:groupId/grocery` | required (any member); role-gated on `section` | `{ name, category, section, quantityText?, orderIndex? }` | `category` is one of `PRODUCE`/`DAIRY_AND_EGGS`/`MEAT_AND_SEAFOOD`/`BAKERY`/`PANTRY`/`FROZEN`/`BEVERAGES`/`SNACKS`/`HOUSEHOLD`/`OTHER`; `section` is `SUGGESTED`/`THIS_WEEK`/`STAPLES`. A `PARTICIPANT` may only create with `section: SUGGESTED` (`403` for any other section — the "suggest an item" path); a `MANAGER` may create with any section (the "add directly to the real list" path). |
| PATCH | `/groups/:groupId/grocery/:id/accept` | **MANAGER only** | — | Moves a `SUGGESTED` item to `THIS_WEEK`. `403` for a `PARTICIPANT`, `409` if the item isn't currently `SUGGESTED`. |
| PATCH | `/groups/:groupId/grocery/:id` | required (any member); field-gated by role | Any subset of `{ name, category, quantityText, section, isChecked, orderIndex, aisleId }` | **Asymmetric on purpose** — see "Group grocery list" below. Any member may set `isChecked`/`orderIndex`/`aisleId` (routine day-to-day list use, including "My Layout" placement). Only a `MANAGER` may set `name`/`category`/`quantityText`/`section` (editing what's on the list). A request from a `PARTICIPANT` that touches even one manager-only field is rejected wholesale (`403`) — nothing is partially applied. `aisleId` may be `null` (explicitly "Unsorted") or a `GroupStoreAisle` id belonging to this same group (`400` if it names an aisle in another group, or one that doesn't exist); sending it at all — including `null` — also sets `aisleManuallySet: true` on the item (see "My Layout" below). Checking an item off (`isChecked` `false` -> `true`) also records a `GroupGroceryHistoryEntry` for it — see "Grocery history" below. |
| DELETE | `/groups/:groupId/grocery/:id` | depends on the item's current `section` | — | `SUGGESTED`: **MANAGER, or the item's own original suggester** (rejecting a suggestion) — anyone else gets `403`. `THIS_WEEK`/`STAPLES`: **any member** (routine list maintenance — "we bought it" / "we don't need it") — no extra check. |
| GET | `/groups/:groupId/grocery/history` | required (member) | — | `{ items: [{ name, category, addedAt }] }` — every distinct item name this group has ever checked off, alphabetical. See "Grocery history" below for why this is a durable log, not a live query. |
| GET | `/groups/:groupId/grocery/aisles` | required (member) | — | `{ aisles: [...] }` — every `GroupStoreAisle` for the group, sorted by `sortIndex`. Seeds ten starter aisles (one per `GroceryCategory`) the first time this is called for a group with none yet — see "My Layout" below. |
| POST | `/groups/:groupId/grocery/aisles` | required (any member) | `{ name }` | Creates a custom aisle, appended to the end of the walking order (`sortIndex` = current max + 1). `linkedCategory` is always `null` for a manually-created aisle — only the seeded starters get one. |
| PATCH | `/groups/:groupId/grocery/aisles/:id` | required (any member) | Any subset of `{ name, sortIndex }` | Rename and/or reposition — including a starter aisle, same as the local app. `404` if the aisle doesn't belong to this group. |
| DELETE | `/groups/:groupId/grocery/aisles/:id` | required (any member) | — | Deletes the aisle. Every `GroupGroceryItem` that was manually placed there has both `aisleId` reset to `null` **and** `aisleManuallySet` reset to `false` (not just the former) — so those items fall back to their category's default aisle again, not "explicitly Unsorted". |
| GET | `/groups/:groupId/grocery/staples` | required (member) | — | `{ staples: [...] }` — every `GroupStapleItem` for the group (active and inactive), alphabetical. |
| POST | `/groups/:groupId/grocery/staples` | required (any member) | `{ name, category, defaultQuantityText?, isActive? }` | Creates a standing staple; `isActive` defaults `true`. |
| PATCH | `/groups/:groupId/grocery/staples/:id` | required (any member) | Any subset of `{ name, category, defaultQuantityText, isActive }` | No manager-only field split, unlike the grocery-item `PATCH` above — see "Staples" below for why. |
| DELETE | `/groups/:groupId/grocery/staples/:id` | required (any member) | — | — |

## 6. Recipe sharing

Phase 2a: recipes move from purely on-device SwiftData storage to something
that can also live on this backend and be shared between people, built
directly on the friends/groups layer above. As of Phase 3, the iOS app calls
this too — sharing a recipe from `RecipeDetailView` (via
`RecipeSharePickerSheet`) creates it here and shares it, and the "Shared"
segment of `RecipesHomeView` lists what's been shared back
(`GET /recipe-library/shared-with-me`) and can save a copy locally. See
`prisma/schema.prisma`'s `Recipe`,
`RecipeIngredient`, and `RecipeShare` models for the full data model — field
names there deliberately mirror the iOS model's fields (title, summary,
ordered `instructions`, `servings`/`prepMinutes`/`cookMinutes`, and each
ingredient's name/quantity/unit) so that later wiring is a straightforward
mapping rather than a redesign.

**Visibility model**: every recipe is `PRIVATE` (default, visible only to
its owner) or `SHARED` (has at least one active share). Sharing a recipe
(via `POST /recipe-library/:recipeId/share`) flips `PRIVATE` → `SHARED`
automatically; removing shares never flips it back automatically, even if
that removes the last one — an explicit, intentionally simple choice for
v1 (see the endpoint table above and the code comment on the unshare route)
rather than silently re-deriving visibility from "is there still a share
row" every time one is removed.

**This is deliberately "private + shared with specific friends/groups only"
— there is no public/community recipe library in this phase, and therefore
no moderation/reporting system either** (nothing here is visible to anyone
without an actual relationship to the owner: an accepted friend they
explicitly shared with, or a fellow member of a group they explicitly
shared with). The `RecipeVisibility` enum is written with a comment noting
that a future `PUBLIC` value would be a natural addition — just a new enum
value plus a route that can set it — not a schema rework, but nothing in
this phase sets or reads one.

Sharing reuses Phase 1's anti-stranger rules exactly: sharing directly with
a `userId` requires that person to already be an accepted friend of the
recipe's owner, and sharing with a `groupId` requires the owner to already
be a member of that group — the same checks `POST /groups` and
`POST /groups/:groupId/invite` already enforce. Only the recipe's owner can
share or unshare it; someone it's been shared with cannot re-share it to
someone else in this v1 (no "forwarding" a shared recipe yet).

A recipe's ingredient list is always replaced wholesale on `PATCH` — the
route deletes every existing `RecipeIngredient` row for that recipe and
recreates it from the incoming array, inside one transaction, rather than
diffing/matching individual rows (incoming ingredients have no stable id to
match an existing row against anyway). The one visible side effect: an
ingredient's row `id` changes on every edit that touches ingredients, which
is fine since nothing outside this feature references one.

## 7. Group meal planning

Phase 3: a group's single shared meal plan — every member sees the same
`PlannedMeal`/`MealSuggestion` rows (contrast with recipe sharing above,
which is "my recipe, shared with specific people/groups" — this is
"belongs to the group outright," no separate sharing step). See
`prisma/schema.prisma`'s `PlannedMeal`/`MealSuggestion`/
`MealSuggestionVote` doc comments for the full data model and
`routes/groupMealPlan.js` for the API (the endpoint table above has every
route).

**Decided vs. suggested**, mirroring the "Managers can add stuff to the
meal plans, participants can suggest things to vote on" permission model
from "Group roles" above: a `MANAGER` can `POST` a meal directly onto the
plan (already-decided); any member can `POST` a suggestion instead, which
sits pending a vote until a `MANAGER` either adopts it (turns it into a
real `PlannedMeal` and deletes the suggestion, one transaction) or it's
removed — by a `MANAGER`, or by whoever originally proposed it, same
withdraw-your-own-suggestion pattern the local app already has.

**Recipe-or-restaurant, no backend Restaurant model.** Every row — decided
or suggested — is either recipe-based (`recipeId`, referencing an existing
row in `/recipe-library`) or a restaurant/order-in meal (`restaurantName`,
a plain string, plus `isOrderIn` distinguishing "eating at" from "ordering
in from" the same place — mirrors the iOS `PlannedMeal`/`MealSuggestion`
models' own `isOrderIn` meaning). v1 deliberately has no backend
`Restaurant` model at all; adding one later is a schema addition, not a
rework of this shape. Planning/suggesting a recipe requires it to already
exist **and** be visible to the caller (owner, a direct share, or a shared
group) — the same access check `GET /recipe-library/:recipeId` uses,
applied here so this can't be used to plant an otherwise-invisible
recipeId into a group's shared plan.

**Voting** is a real join table (`MealSuggestionVote`), not a counter or an
array column, specifically so the API can answer "did I already vote for
this" per suggestion (`votedByMe`) as well as a raw count (`voteCount`) —
the iOS `MealSuggestion` model needs exactly that distinction for its own
UI. `POST .../vote` toggles: voting again removes the vote rather than
double-counting it.

`slot`'s values (`BREAKFAST`/`LUNCH`/`DINNER`/`OTHER`) mirror the iOS
`MealSlot` enum's case names exactly (see
`HomeEats/Models/MealSlot.swift`) so a later iOS-wiring task has a direct
mapping rather than a lookup table.

## 8. Group grocery list

Phase 3: a group's single shared grocery list, same "belongs to the group
outright" relationship to `Group` as the meal plan above. See
`prisma/schema.prisma`'s `GroupGroceryItem` doc comment for the full data
model and `routes/groupGrocery.js` for the API.

`category`'s values mirror the iOS `GroceryCategory` enum's case names
exactly (see `HomeEats/Models/GroceryCategory.swift`) — `produce` →
`PRODUCE`, `dairyAndEggs` → `DAIRY_AND_EGGS`, and so on — so a later
iOS-wiring task has a direct mapping.

**No `REJECTED` section, on purpose.** `section` is `SUGGESTED` /
`THIS_WEEK` / `STAPLES` — deliberately matching the local app's *current*
(already-fixed) grocery-list semantics, not its full historical one. The
local `GroceryListSection` Swift enum still technically has a `.rejected`
case, but it's vestigial (kept only for a one-time migration cleanup of old
rows — see `RejectedGroceryItemCleanup.swift`'s own doc comment): rejecting
a suggestion now means deleting the row outright, not parking it in a
permanent rejected bucket. This backend follows that corrected behavior
from day one — there's no rejected state to reintroduce, and
`DELETE /groups/:groupId/grocery/:id` on a `SUGGESTED` item **is** the
reject action.

**The suggest → accept flow**, mirroring "Group roles" the same way the
meal plan does: a `PARTICIPANT` calling `POST` can only create a
`SUGGESTED` item (the participant-suggests path); a `MANAGER` can create
with any section, i.e. add straight onto the real list. `PATCH .../accept`
(`MANAGER` only) moves a `SUGGESTED` item to `THIS_WEEK`; there's no
separate reject endpoint since `DELETE` already covers it.

**`PATCH`'s field-by-field role split** is the one deliberately asymmetric
rule in this whole feature, worth calling out on its own: `isChecked`
(checking something off while shopping) and `orderIndex` (tidying the
list) are routine day-to-day *use* of an already-decided list, open to any
member — nothing about using the list changes what's actually on it.
`name`/`category`/`quantityText`/`section` change what's on the list or how
it's organized, which is a planning decision, so those stay `MANAGER`-only,
same as adding an item directly. The route validates this field-by-field
(not route-wide): a `PARTICIPANT`'s request touching only
`isChecked`/`orderIndex` succeeds; the moment it also touches a
manager-only field, the *whole* request is rejected (`403`) rather than
silently applying the allowed subset — so a client always gets an explicit
signal instead of a partially-applied update it might not notice.

**`DELETE`'s section-dependent rule**: removing a `SUGGESTED` item follows
the same "manager or original proposer" rule as withdrawing a meal
suggestion; removing a `THIS_WEEK`/`STAPLES` item is routine maintenance
("we bought it" / "we don't need it after all") open to any member. The
rule is decided by the item's section *at delete time*, not by who added
it.

### "My Layout" (group-scoped aisles)

`GroupStoreAisle` (see `routes/groupGroceryAisles.js`) is the group-scoped
counterpart of the local `StoreAisle` model — a household-defined
arrangement of the shared list into the aisles of their actual store,
independent of `category`. `GroupGroceryItem` carries the placement itself
directly (`aisleId` + `aisleManuallySet`), rather than a separate join
table keyed by item name the way the local `ItemAisleAssignment` is: local
keys by name because a `GroceryItem` row can, in principle, get
regenerated; a `GroupGroceryItem` row never does — it lives exactly as
long as it exists, created once by `POST` and only ever mutated or
deleted — so a plain FK column on the row loses nothing while avoiding
porting the iOS canonicalizer's pluralization-aware name-matching logic
server-side. `aisleManuallySet` is what stands in for the local model's
"row exists vs. doesn't" trick for distinguishing "never placed" from
"explicitly placed in Unsorted" (`aisleId: null` with `aisleManuallySet:
true`) — a client should ignore `aisleId` entirely while
`aisleManuallySet` is `false` and fall back to whichever aisle has
`linkedCategory === category`, exactly like the local
`GroceryListView.resolvedAisleID` does. This backend never computes that
fallback itself, same "client groups/filters locally" philosophy as `GET
/groups/:groupId/grocery` not pre-splitting by category/section.

**Default seeding — read this before wiring up the iOS side.** Locally,
`SampleDataSeeder` seeds ten starter aisles (one per `GroceryCategory`,
matching "By Category"'s own grouping and ordering) once, at first app
launch — a single on-device process has an obvious "first launch" hook. A
multi-tenant backend has no equivalent moment, and this task's constraints
rule out adding seeding to `POST /groups` in `routes/groups.js`. Instead,
**`GET /groups/:groupId/grocery/aisles` seeds a group's ten starter
aisles the first time it's called for a group with zero `GroupStoreAisle`
rows** — same "only while completely empty" guard as the iOS seeder, just
lazily triggered by the first read instead of by process launch. A group
whose "My Layout" is never opened simply has zero aisle rows (nothing
reads them); the first call for a given group populates the same ten
aisles, in the same order, iOS would have. **This means a later iOS-wiring
task needs to actually call `GET .../grocery/aisles` (not just read some
other response) for "My Layout" to open pre-grouped instead of empty** —
if that call is skipped, every group will appear to start with everything
in "Unsorted" again, exactly the bug this feature exists to avoid.

Aisle CRUD (create/rename/reposition/delete) and item-to-aisle placement
(`PATCH .../grocery/:id`'s `aisleId`) are both **open to any member**, not
`MANAGER`-only — a deliberate call: neither changes what's actually on the
list (`category` is untouched by either), only how it's arranged for
walking the store, the same "routine, day-to-day use" bucket
`isChecked`/`orderIndex` already sit in above. The local app itself
doesn't gate aisle management at all (it's single-user), reinforcing that
this is personal/household organizing, not a planning decision. Deleting
an aisle resets both `aisleId` **and** `aisleManuallySet` to their
defaults on every item that pointed at it (in the same transaction as the
delete) — not just `aisleId` — so those items fall back to their
category's default aisle again rather than reading as "explicitly
Unsorted".

### Staples

`GroupStapleItem` (see `routes/groupGroceryStaples.js`) is the group-scoped
counterpart of the local `StapleItem` model — a standing list of recurring
household items (milk, paper towels, ...), independent of any recipe or
the current week's list. It's distinct from the pre-existing
`GroupGrocerySection.STAPLES` value on `GroupGroceryItem` (Phase 3,
unchanged here): that's a tag on one specific line already on the live
list; this is the separate template those lines get manually copied
from — the same two-concepts-coexisting shape the local app itself has
(`GroceryListSection.staples`, still reachable from `AddGroceryItemSheet`,
alongside the separate `StapleItem`/`StaplesManagerView`).

Every staples route is **open to any member**, including create/edit/
delete — not just toggling `isActive`. Reasoning: a staple is a
reference/template with no direct effect on the live list (see the next
paragraph), so there's no "what's actually being bought" stake for a
`MANAGER` gate to protect, unlike `GroupGroceryItem`'s `name`/`category`/
`quantityText`/`section`. This codebase's own precedent already points the
same way: `DELETE /groups/:groupId/grocery/:id` already lets **any**
member delete a `STAPLES`-section item as "routine list maintenance" — a
`GroupStapleItem` is a lower-stakes version of that same idea (a template,
not a live list line), so gating it more tightly would be the
inconsistent choice. It reads as closer to "routine household admin" (the
digital notepad-on-the-fridge, anyone can add to it) than "meal planning."
Worst case for getting this wrong is clutter, not confusion about what's
being bought.

`isActive` is carried over field-for-field for iOS interface parity, but
**toggling it has no downstream effect in this backend** — deliberately,
matching current local behavior exactly. There is no group-scoped
"regenerate suggestions from active staples" endpoint, and even locally,
the one place that *could* merge active staples into suggestions
(`GroceryListBuilder.regenerate`) is never actually called with real
staples — `GroceryListView.generateSuggestions` always passes `[]`, per
that file's own doc comment, so a short meal-plan result doesn't get
buried in unrelated staples. Wiring staples into suggestion-generation
here would make this backend do something the local app itself
deliberately doesn't do yet, so this endpoint stores/returns `isActive`
faithfully and stops there.

### Grocery history (past-groceries quick-add)

`GET /groups/:groupId/grocery/history` is the group-scoped counterpart of
the local "From Your Past Groceries" section, backed by a new
`GroupGroceryHistoryEntry` table — **not** a live query over
`GroupGroceryItem`, which is the simpler approach this feature's spec
correctly prefers by default, and the one to reach for first absent a
concrete reason otherwise.

The reason found here: `GroupGroceryItem` rows are hard-deleted when
removed from the list, and per this file's own `DELETE` rule above, "we
bought it" is an everyday, established reason a `THIS_WEEK`/`STAPLES` row
gets deleted — not an edge case. A query over *currently-existing* rows
would lose an item's name from "history" at the exact moment someone
finishes buying it and clears it off the list, which is the one moment
this feature most needs to remember it for. A derived query can't express
"remember this even after the row it came from is gone," so a small
durable table earns its keep rather than being redundant bookkeeping to
keep in sync — it's populated automatically, at exactly one trigger point,
by the same request that would otherwise lose the information, so there's
no separate sync step that could drift.

The trigger mirrors the local `GroceryItemRow.recordAsHistorical` exactly:
`PATCH /groups/:groupId/grocery/:id` upserts one of these (a no-op if
already known) whenever `isChecked` transitions `false` -> `true` — inside
the same transaction as the item update, so a history entry is never
recorded without the checkbox actually flipping or vice versa. Recording
only on that transition (not on every create/delete) deliberately keeps a
`SUGGESTED` item that was rejected without ever being bought out of
history. Dedup is by `normalizedName` (lowercased/trimmed) rather than the
iOS canonicalizer's pluralization-aware `canonicalKey` — good enough to
stop the same typed name (modulo case/whitespace) from creating two rows,
without porting that algorithm server-side.

## Notes

- New routes here (`/recipe-library`) are mounted separately from the
  pre-existing, unauthenticated `/recipes/extract` and `/recipes/recommend`
  routes in `index.js` (Claude-powered recipe extraction/recommendation,
  with no accounts involved at all) — different prefix entirely, so there's
  no risk of the two ever colliding or being confused with each other, even
  though nothing here would actually clash method+path with those.
- Free-tier Render web services spin down after inactivity and take a few
  seconds to wake back up on the next request — fine for a household app,
  worth knowing so a "slow first search"/"slow first recommendation" isn't
  mistaken for a bug.
- `/restaurants/search` also returns each place's Google photo (as a stable
  `photoName` reference, not the image itself), and `/restaurants/photo`
  fetches the actual bytes on demand — the app requests one only for a
  restaurant someone actually adds and views, not for every search result,
  since each fetch is a separate billed Google request.
- `/restaurants/details?placeId=...` (Place Details) returns a restaurant's
  hours, phone number, and reviews — the detail page's own separate,
  billed request, made only when that restaurant's page is actually
  opened. That's what lets `RestaurantDetailView` show reviews/hours
  directly instead of only linking out to the Google Maps app.
- Every `/recipes/*` call costs real money the moment a key is configured
  (Claude Opus 5 — see the model table in the Anthropic Console for current
  pricing). Fine for household-scale use; if this app ever gets real
  traction, add per-user rate limiting here before that happens.
- `/restaurants/search-natural` costs more than a plain search: one small
  Claude call to interpret the sentence, plus a Places Text Search, plus a
  Geocoding API call whenever the sentence names a specific place. Still
  fine for household-scale, occasional use — just not something to wire up
  to fire on every keystroke the way plain search does.
- Phone numbers are only ever returned to someone with an actual
  relationship to that person — an accepted friend, or a fellow member of a
  group they're both in (see the endpoint table above). No route hands back
  an arbitrary stranger's phone number.
- Twilio Verify bills per verification check, same "real money once
  configured" story as the `/recipes/*` Claude calls above — fine at
  household/friend-group scale, worth knowing before wiring this up to
  something high-traffic.
- **Rate limiting**: `POST /auth/request-code` is throttled by a small
  in-memory limiter (`lib/rateLimit.js`) — 5 requests per phone number per
  hour, 20 per IP per hour — on top of Twilio Verify's own Fraud
  Guard/rate-limiting, since this route fires a billed Twilio call before
  Twilio ever gets a say. `429` with `{ "error": "..." }` when exceeded. The
  limiter's state is per-process (fine for this app's single Render
  instance — see the deploy section above — but it resets on every
  deploy/restart and wouldn't be shared across instances if this ever
  scales past one); `index.js` sets `app.set("trust proxy", true)` so the
  per-IP half of this actually sees the real client IP through Render's
  reverse proxy rather than the proxy's own address.
- `Group.createdByUserId` is nullable (`onDelete: SetNull` on its relation
  to `User`) rather than the group cascading away when its creator's
  account is later deleted (there's no delete-account route yet, but there
  will be) — deleting the creator just clears who created it; the group and
  every other member's membership, invites, and recipe shares are
  unaffected.
- There's no delete-account or remove-phone-number route yet. There IS a
  group role system as of Phase 3 (`GroupRole`: `MANAGER`/`PARTICIPANT` —
  see "Group roles" above), but deliberately no promote/demote-role
  endpoint — a reasonable thing to add once real usage shows it's needed,
  out of scope for this phase.
