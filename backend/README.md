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
meal plan and shared grocery list built on top of it. Phase 5 makes every
group addition require the recipient's actual consent (no more instantly
adding an accepted friend), adds promote/demote so a group can have several
MANAGERs, and adds a combined `GET /notifications` feed. See "Accounts,
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
curl "http://localhost:4000/cities/search?q=Green"
curl "http://localhost:4000/cities/ChIJnQ5tX9lQWokR0HeeAd-VXOs"
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
- The profile's City field (`ProfileCompletionStepView`, `EditProfileView`)
  becomes a real search-as-you-type field instead of plain free text — type
  a few letters, pick a real city from the dropdown, and City/State/Country
  all fill in together from that one selection. See "City search" below.
  Falls back to a plain text field (no dropdown that can never return
  anything) when this key isn't configured, same "disabled/degraded rather
  than half-working" pattern as the ✨ button above.

## 4b. City search

Two more endpoints on the same Google Places proxy as `/restaurants/*`
above, powering the profile's City field's type-ahead (see
`CitySearchField.swift` in the iOS app). Both unauthenticated, matching how
`/restaurants/*` is mounted — this needs to work even for an account that
verified its phone number but hasn't finished onboarding yet (`RootView`'s
profile-completion gate, reached before a JWT means anything to this app in
practice).

| Method | Path | Notes |
|---|---|---|
| GET | `/cities/search?q=<partial city name>` | Proxies Places API (New)'s Autocomplete endpoint (`POST places.googleapis.com/v1/places:autocomplete`), restricted to city-level results via `includedPrimaryTypes: ["locality"]`. Returns `{ predictions: [{ placeID, mainText, secondaryText }] }` — `mainText`/`secondaryText` are Google's own `structuredFormat` split of a prediction ("Greenwich" / "CT, USA"), exactly what a dropdown row wants. `400` if `q` is missing/empty, `500` if `GOOGLE_PLACES_API_KEY` isn't configured, `502` if the Places API call itself fails. |
| GET | `/cities/:placeID` | Proxies Places API (New)'s Place Details endpoint (`GET places.googleapis.com/v1/places/{placeID}`), field-masked to `addressComponents` only. Returns `{ city, state, country }`, each pulled from the component whose `types` includes `locality`/`administrative_area_level_1`/`country` respectively, using that component's `longText` (not `shortText`) so a result lines up with the iOS app's own `USState.all`/`CountryCode.all` full-name lists ("California", not "CA"). This is the call that actually makes "pre-populates everything" work — a prediction's own display text from `/cities/search` isn't reliably parseable into precise city/state/country across locales/formats, so the app makes this separate, structured-data call once, right after a suggestion is tapped. Any of the three can legitimately come back `null` if Google's response has no matching component for that place — the iOS side leaves the corresponding field/picker untouched rather than clearing it when that happens, so an already-picked State/Country never gets silently blanked out by an incomplete Details response. `400` if `placeID` is missing, `500`/`502` same as above. |

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

**Invites and consent.** An `Invite` (someone added by phone number, or by
`userId`, to a group or as a friend) never grants anything by itself — it's
a standing, revisitable request the invited person has to actually agree
to. Two different things can happen to it depending on whether it named a
`groupId`:

- **No `groupId` (a plain "become my friend" invite)** resolves into an
  ordinary incoming friend request — the same `PENDING` `Friendship` row,
  and the same `GET /friends`'s `incomingRequests` entry, as a friend
  request sent directly — once the invited phone number signs up (if it
  wasn't already a user) via `POST /auth/verify-code`. From there it's
  accepted/declined exactly like any other friend request, via
  `POST /friends/:friendshipId/accept`/`decline`. **This path is completely
  unchanged by Phase 5** — see `resolveInvitesForAcceptedFriendship`/
  `cancelInvitesForDeclinedFriendship` in `routes/friends.js`.
- **`groupId` set (from `POST /groups/:groupId/invite`)** is where Phase 5
  changes things — see below.

**Phase 5: every group addition requires the recipient's consent, with no
exceptions — including someone who is already an accepted friend of the
inviter.** Before this phase, `POST /groups/:groupId/invite`'s `userId`
path (always an accepted friend) and its `phoneNumber` path when that
number matched an accepted friend both created the `GroupMembership`
instantly, with zero chance to decline — a real gap, since "we're friends"
and "I consent to being in this specific group with whoever else is in it"
are genuinely different things to agree to. **No path in this route creates
a `GroupMembership` directly anymore.** Every addition — `userId` or
`phoneNumber`, friend or stranger — now creates/reuses a PENDING `Invite`
for that phone number + this `groupId`, unifying what used to be two
separate near-duplicate flows into one (see the route's own doc comment in
`routes/groups.js` for the full before/after reasoning). `userId` still
requires an accepted friend (`400` otherwise, same as before and as group
creation); `phoneNumber` still has no such restriction, for the same
anti-enumeration reason described under "Phone-number privacy" below.

That Invite resolves into real `GroupMembership` one of two ways, matching
the two bullets above: through `resolveInvitesForAcceptedFriendship` if the
invited phone number wasn't a user yet and later accepts the friend request
that invite also queued for them, or — the case that motivated Phase 5,
since there's no *new* friendship event to hook into for someone who's
already an accepted friend — directly, via the new endpoints in
`routes/invites.js`:

- `GET /invites` — the caller's own pending group Invites (matched by
  their own phone number; see the endpoint table below).
- `POST /invites/:inviteId/accept` — recipient only; creates the
  `GroupMembership` (as `PARTICIPANT`) and marks the Invite `RESOLVED`.
- `POST /invites/:inviteId/decline` — recipient only; marks the Invite
  `DECLINED` (a new, distinct `InviteStatus` value — see below) and grants
  nothing.

**The other side of the same Invite: `GET /groups/:groupId/invites`.**
Everything above is the *recipient's* view. A group's own `MANAGER`s need
the opposite view — who has WE invited, and who's said no — which is what
this route (in `routes/groups.js`, not `routes/invites.js`) is for. It is
**not part of Phase 5 itself**; it was added afterwards, by the iOS-wiring
task that consumes these endpoints, once it was clear `GET /groups/:groupId`
carries no invite data at all and a `MANAGER` otherwise had no way to see a
group's own outstanding invites (needed for that task's "Pending Invites"
UI). See the endpoint table below for its exact shape; it mirrors this
phase's own conventions (`MANAGER`-only, PENDING/DECLINED only, resend via
the same `POST /:groupId/invite` route) rather than inventing new ones.

**`DECLINED` vs. `CANCELLED`.** `InviteStatus` gained a `DECLINED` value in
Phase 5, kept deliberately distinct from the pre-existing `CANCELLED`:
`CANCELLED` means this Invite's story ended because something *else*
happened (its tied friend request was declined — nobody actually answered
*this* Invite), while `DECLINED` means the recipient looked at this
specific group Invite and said no, via the endpoint above. See the
`InviteStatus` doc comment in `prisma/schema.prisma` for the full
reasoning.

**Resend after a decline — no new endpoint needed.** The "already invited"
`409` check in `POST /groups/:groupId/invite` only ever blocks on a
`PENDING` row for that phone number + group; a `DECLINED` (or `CANCELLED`)
one doesn't block a fresh invite. So calling that same route again after a
decline already works, with no separate `POST /invites/:inviteId/resend`
endpoint required — confirmed by testing it directly (see "What was
verified" further down). Who may trigger it: any current `MANAGER` of the
group, not specifically the original sender — the route was already
`MANAGER`-only, not sender-restricted, and Phase 5's multi-manager model
(below) means every current `MANAGER` already has equal standing to invite
in the first place.

**Group roles (Phase 3, extended Phase 5).** Every `GroupMembership` now
carries a `role`: `MANAGER` or `PARTICIPANT` — a two-tier permission model,
not the free-for-all every-member-is-equal v1 group membership had before
Phase 3. A group's creator starts `MANAGER`; anyone added afterwards — via
`memberUserIds` on `POST /groups`, or once their `POST /groups/:groupId/invite`-
queued `Invite` is accepted (see above) — starts `PARTICIPANT`. Existing
groups from before Phase 3 were backfilled the same way: the membership row
matching `group.createdByUserId` became `MANAGER`, every other membership
became `PARTICIPANT` — and since `createdByUserId` is nullable (see the
note on it further down), a group whose creator's account was already
deleted by the time of the backfill has no way to know who to promote, so
every one of its memberships was simply left `PARTICIPANT`. See the
`GroupRole`/`GroupMembership` doc comments in `prisma/schema.prisma` for the
full reasoning, and its migration
(`prisma/migrations/20260913020000_group_roles_meal_plan_grocery`) for the
exact backfill.

Roles tighten group-*management* itself: `POST /groups/:groupId/invite` is
`MANAGER`-only (a `PARTICIPANT` gets `403`), and
`DELETE /groups/:groupId/members/:userId` removing someone else is
`MANAGER`-only too — but removing *yourself* (leaving) still works
regardless of role, at any time, for anyone (subject to the last-manager
guard below). `GET /groups/:groupId`'s member list includes each member's
`role` so a client can show/gate on it without a second request.

**Multiple managers, with promote/demote (Phase 5).** A group having
several `MANAGER`s at once was already fully supported before Phase 5 —
nothing in the schema or the existing authorization checks ever assumed
exactly one; what was missing was any way to actually change someone's role
after the fact. Phase 5 adds that:

- `POST /groups/:groupId/members/:userId/promote` — `MANAGER`-only (`403`
  for a `PARTICIPANT` or a non-member). Sets the target's role to
  `MANAGER`. A target already `MANAGER` is a harmless no-op (`200`), not an
  error. Once someone is promoted, they have exactly the same standing as
  any other `MANAGER` — including being able to promote or demote others,
  or invite new members — nothing tracks who promoted whom or treats one
  `MANAGER` as senior to another.
- `POST /groups/:groupId/members/:userId/demote` — `MANAGER`-only. Sets the
  target's role to `PARTICIPANT`, **except blocked (`409`) when it would
  leave the group with zero `MANAGER`s while other members remain** — see
  the last-manager guard below. A target already `PARTICIPANT` is a
  harmless no-op (`200`). Demoting yourself is allowed as long as it
  doesn't trip that same guard.

Both return `{ member: publicMember(updatedMembership) }` — the identical
shape `GET /groups/:groupId`'s member list and `POST /groups/:groupId/invite`'s
old (pre-Phase-5) direct-add response used, for consistency.

**The last-manager guard, and the pre-existing gap it closes.** Demoting or
removing/leaving is blocked (`409`, with a message suggesting "promote
someone else first") whenever the target is the group's **sole remaining
MANAGER and other members would be left behind** — i.e. a group can never
be left with participants stuck in it and nobody who can invite new
members, decide anything, or promote one of them back. It is **not**
blocked when the target is a `PARTICIPANT` (removing/demoting a participant
never changes the manager count), when at least one other `MANAGER` would
remain, or when the target is the group's *only* member overall (leaving/
demoting then can't strand anyone else — the group either becomes
memberless or has one ungoverned participant, neither of which is the
"stuck, unfixable" scenario this guards against). This same guard now
applies to both `POST .../demote` and `DELETE /groups/:groupId/members/:userId`
(leave/remove) — the latter was a known, previously-flagged gap: before
Phase 5 added promote/demote, there was no way for a stuck group to recover
from losing its last manager at all, so blocking the removal would have
just relocated the same problem ("can't leave/remove them, and also can't
fix it" isn't much better than "can leave/remove them, and now nobody can
fix it"). Now that promoting someone else first is a real fix, guarding the
removal is worth doing. See `wouldStrandGroup` in `routes/groups.js` for the
shared implementation both routes call.

Roles also gate the group meal-plan and grocery-list routes below, with
their own (different, more field-grained in grocery's case) rules — see
"Group meal planning" and "Group grocery list".

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
| GET | `/me` | required | — | Returns `{ user: { id, phoneNumber, displayName, firstName, lastName, city, state, country, createdAt, profileComplete } }` for the caller. `profileComplete` is a derived boolean (`true` once `firstName`/`lastName`/`city`/`state`/`country` are all non-empty) — the client-side app treats those five fields as mandatory before letting someone past onboarding (see the iOS `RootView`'s completion gate), but that's an application-level rule, not a database constraint: all five columns stay nullable so an account that predates this requirement (or one instantiated via `POST /auth/verify-code` a moment ago, before it has filled anything in) still loads without error, just with `profileComplete: false`. |
| PATCH | `/me` | required | `{ displayName?, firstName?, lastName?, city?, state?, country? }` | Partial update — any subset of these fields, all independently optional; omitted keys are left alone. Each provided field must be non-empty (`400` otherwise — none of these are meant to be clearable back to `null` once set). `400` if the body has none of these keys at all. Returns the updated `{ user }` in the same shape as `GET /me`. Note that this endpoint's own optionality is unrelated to `profileComplete` above — a client is expected to call this once per field while onboarding (or edit one field at a time later from Settings), not send all five at once. |
| POST | `/friends/request` | required | `{ phoneNumber }` | Sends a friend request. If that number belongs to an existing user with no prior relationship, creates a `PENDING` `Friendship`; if a request in the other direction was already pending, this accepts it instead (`200`, `{ friendship, autoAccepted: true }`). If the number isn't a user yet, creates an `Invite` (no group). The first two of those report back identically — `201`, `{ "status": "requested" }` — see "Phone-number privacy" above. `409` if already friends, already pending, or already invited. |
| POST | `/friends/:friendshipId/accept` | required | — | Recipient only; `403` otherwise, `409` if not `PENDING`. Also resolves any tied `Invite`(s) into `GroupMembership` — see "Invites and consent" above. |
| POST | `/friends/:friendshipId/decline` | required | — | Recipient only; same error shape as accept. Also cancels any tied `Invite`(s) (see "Invites and consent" above). |
| GET | `/friends` | required | — | `{ friends: [...], incomingRequests: [...], outgoingRequests: [...] }` — accepted friends, plus separate pending lists for requests you've received and sent. |
| POST | `/groups` | required | `{ name, memberUserIds?: string[] }` | Creates a group with the caller as its sole initial member (`MANAGER`). Each `memberUserIds` entry must already be an accepted friend of the caller (`400` otherwise, so you can't target a stranger's id) — as of Phase 5 this no longer adds them as a member directly; each queues a PENDING `Invite` for the new group (the same mechanism `POST /:groupId/invite`'s `userId` path uses), and they join as `PARTICIPANT` only once they accept it via `POST /invites/:inviteId/accept`. `memberUserIds` is capped at 100 entries (`400` if exceeded). Returns `{ group }` — `members` reflects only the caller until any invites are accepted. |
| GET | `/groups` | required | — | `{ groups: [...] }` — every group the caller belongs to (a lightweight list; use the next route for members/roles). |
| GET | `/groups/:groupId` | required | — | `{ group }` with the full member list (each entry includes `role`), phone numbers included (safe here — everyone returned is a fellow member of this same group). `403` if the caller isn't a member. |
| POST | `/groups/:groupId/invite` | **MANAGER only** | `{ userId }` **or** `{ phoneNumber }` | A member who isn't a `MANAGER` gets `403` (see "Group roles" above); a non-member also gets `403`. **Phase 5: never creates a `GroupMembership` directly** — `userId` (must be one of the caller's accepted friends, `400` otherwise) or `phoneNumber` (any number at all, friend or stranger — see "Phone-number privacy" below) always queues/reuses a PENDING `Invite` with this `groupId` instead, reporting back identically either way (`201`, `{ "status": "invited" }`). If the phone number is already a user with no prior relationship to the caller, also sends them an ordinary friend request. `409` if already a member, or if that phone number already has a `PENDING` invite to this group (calling this again after a `DECLINED`/`CANCELLED` one succeeds — see "Resend after a decline" above). See "Invites and consent" above for the full flow and how the queued `Invite` is actually accepted/declined. |
| GET | `/invites` | required | — | `{ invites: [{ id, group: { id, name }, invitedBy: { id, displayName, phoneNumber }, createdAt }] }` — the caller's own pending **group** Invites (matched by their own phone number), newest first. A bare "become my friend" Invite (no `groupId`) never appears here — see "Invites and consent" above. |
| GET | `/groups/:groupId/invites` | **MANAGER only** | — | **Not part of Phase 5 — added by the iOS-wiring task that consumes it**, since `GET /groups/:groupId` carries no invite data at all and a MANAGER otherwise has no way to see who's already been invited to their own group. `403` for a non-`MANAGER` or non-member. `{ invites: [{ id, invitedPhoneNumber, invitedUser: { id, displayName, phoneNumber } \| null, invitedBy: { id, displayName, phoneNumber }, status, createdAt }] }` — every `PENDING` or `DECLINED` Invite standing against this group, newest first (`RESOLVED` ones are just ordinary members already visible in the member list; `CANCELLED` ones ended via something else happening — see "`DECLINED` vs. `CANCELLED`" above — so neither is worth surfacing here). `invitedUser` is `null` unless `invitedPhoneNumber` already belongs to a Home Eats user. A resend is `POST /groups/:groupId/invite` again with the same target — see "Resend after a decline" above; there's no dedicated resend route here either. |
| POST | `/invites/:inviteId/accept` | required (recipient only) | — | `403` if the caller's phone number doesn't match the Invite's `invitedPhoneNumber`; `400` if the Invite has no `groupId` (use `POST /friends/:friendshipId/accept` instead); `409` if not `PENDING`; `404` if it doesn't exist. Creates the `GroupMembership` (`PARTICIPANT`) and marks the Invite `RESOLVED`, in one transaction. Returns `{ invite }`. |
| POST | `/invites/:inviteId/decline` | required (recipient only) | — | Same checks as accept. Marks the Invite `DECLINED` (distinct from `CANCELLED` — see "Invites and consent" above) and grants nothing. Returns `{ invite }`. |
| POST | `/groups/:groupId/members/:userId/promote` | **MANAGER only** | — | `403` for a `PARTICIPANT` or non-member; `404` if the target isn't a member. Sets the target's role to `MANAGER`; a no-op (`200`) if already `MANAGER`. Returns `{ member }` (same shape as `GET /groups/:groupId`'s member list). |
| POST | `/groups/:groupId/members/:userId/demote` | **MANAGER only** | — | Same auth/404 as promote. Sets the target's role to `PARTICIPANT`; a no-op (`200`) if already `PARTICIPANT`. `409` if the target is the group's sole remaining `MANAGER` and other members would be left behind — see "The last-manager guard" above. Returns `{ member }`. |
| DELETE | `/groups/:groupId/members/:userId` | required (self always allowed; **MANAGER** for anyone else) | — | Leave (pass your own id) — always allowed for any member, regardless of role. Removing someone ELSE's membership is `MANAGER`-only (`403` for a `PARTICIPANT` trying to remove another member). `403` if the caller isn't a member at all, `404` if the target isn't a member. **Phase 5**: `409` if the target is the group's sole remaining `MANAGER` and other members would be left behind — same guard as demote, see "The last-manager guard" above. |
| GET | `/notifications` | required | — | `{ count, friendRequests: [...], groupInvites: [...] }` — a combined "things waiting on my response" feed. `friendRequests` is byte-for-byte the same shape as `GET /friends`'s `incomingRequests`; `groupInvites` is byte-for-byte the same shape as `GET /invites`'s `invites`. `count` is just the sum of both lists' lengths. See "Notifications" below. |
| POST | `/recipe-library` | required | `{ title, summary?, ingredients: [{ name, quantity?, unit? }], instructions: string[], servings?, prepMinutes?, cookMinutes?, photoBase64? }` | Creates a recipe owned by the caller, starting `PRIVATE`. `ingredients`/`instructions` are each capped at 200 entries (`400` if exceeded). `photoBase64` is the recipe's photo, base64-encoded, decoded-size-capped at 5MB (`400` if exceeded, or if it's not valid base64) — see "Recipe sharing" below. Returns `{ recipe }` including its ingredients. |
| GET | `/recipe-library/mine` | required | — | `{ recipes: [...] }` — every recipe the caller owns, any visibility. |
| GET | `/recipe-library/shared-with-me` | required | — | `{ recipes: [...] }` — every recipe shared directly with the caller, or via any group they belong to. One entry per share (a recipe shared with you two ways appears twice); each entry carries a `share: { sharedAt, sharedBy, sharedWithGroup }` so the UI can show who shared it / via which group. |
| GET | `/recipe-library/:recipeId` | required | — | `{ recipe }` with full ingredient detail. `403` unless the caller is the owner, a direct share target, or a member of a group it's shared with; `404` if it doesn't exist. |
| PATCH | `/recipe-library/:recipeId` | required | Any subset of the POST body's fields | Owner only (`403` otherwise). Omitted fields are left unchanged; an included `ingredients` array wholesale-replaces the recipe's ingredient list (delete-and-recreate, not diffed/patched row-by-row); an explicit `photoBase64: null` clears the photo, same omitted-vs-null rule as `summary`/`servings`/etc. |
| DELETE | `/recipe-library/:recipeId` | required | — | Owner only (`403` otherwise). Cascades to its ingredients and shares. |
| POST | `/recipe-library/:recipeId/share` | required | `{ userId }` **or** `{ groupId }` | Owner only — sharing further isn't delegated to someone it's already shared with. `userId` must be an accepted friend of the owner; `groupId` must be a group the owner belongs to (`400` otherwise, same anti-stranger rule as `/groups`). Flips visibility `PRIVATE` → `SHARED` if needed. `409` if already shared with that exact user/group. |
| DELETE | `/recipe-library/:recipeId/share/:shareId` | required | — | Un-share, owner only (`403` otherwise). Does **not** revert visibility back to `PRIVATE` even if it was the last share — see "Recipe sharing" below. |
| GET | `/groups/:groupId/meal-plan` | required (member) | — | `{ plannedMeals: [...], suggestions: [...] }` — every decided meal and every pending suggestion for the group, no date filtering server-side (client filters locally). Each suggestion includes `upvoteCount`, `downvoteCount`, and `myVote` (`"UP"`/`"DOWN"`/`null` — the caller's own vote, if any). `403` if the caller isn't a member. |
| POST | `/groups/:groupId/meal-plan` | **MANAGER only** | `{ date, slot, recipeId }` **or** `{ date, slot, restaurantName, isOrderIn? }` | Directly decides a meal (created already-decided, not a suggestion). `slot` is one of `BREAKFAST`/`LUNCH`/`DINNER`/`OTHER`. Exactly one of `recipeId`/`restaurantName` (`400` otherwise); `recipeId` must reference a recipe that already exists in `/recipe-library` **and** is visible to the caller — owner, a direct share, or a shared group (`400` otherwise). `403` for a `PARTICIPANT`. |
| DELETE | `/groups/:groupId/meal-plan/:id` | **MANAGER only** | — | `403` for a `PARTICIPANT`, `404` if the planned meal doesn't belong to this group. |
| POST | `/groups/:groupId/meal-plan/suggestions` | required (any member) | Same body shape as `POST /groups/:groupId/meal-plan` | The Participant-facing "suggest a recipe/restaurant/order-in for a vote" action. The proposer is automatically counted as having voted for their own suggestion. |
| POST | `/groups/:groupId/meal-plan/suggestions/:id/vote` | required (any member) | `{ direction: "UP" \| "DOWN" }` | Thumbs up/down on the suggestion. Voting the same direction again retracts the vote; voting the opposite direction switches it. Returns the updated `{ suggestion }` with `upvoteCount`/`downvoteCount`/`myVote`. |
| POST | `/groups/:groupId/meal-plan/suggestions/:id/adopt` | **MANAGER only** | — | Converts the suggestion into a decided `PlannedMeal` (same date/slot/recipe-or-restaurant) and deletes the suggestion, in one transaction. `403` for a `PARTICIPANT`. |
| DELETE | `/groups/:groupId/meal-plan/suggestions/:id` | **MANAGER, or the suggestion's own proposer** | — | Lets you withdraw your own suggestion even without being a manager (mirrors the local app's own suggestion-withdrawal pattern); anyone else gets `403`. |
| GET | `/groups/:groupId/grocery` | required (member) | — | `{ items: [...] }` — every item on the group's shared list; client groups/filters by category/section locally. |
| POST | `/groups/:groupId/grocery` | required (any member); role-gated on `section` | `{ name, category, section, quantityText?, quantityCount?, orderIndex? }` | `category` is one of `PRODUCE`/`DAIRY_AND_EGGS`/`MEAT_AND_SEAFOOD`/`BAKERY`/`PANTRY`/`FROZEN`/`BEVERAGES`/`SNACKS`/`HOUSEHOLD`/`OTHER`; `section` is `SUGGESTED`/`THIS_WEEK`/`STAPLES`. `quantityCount` (an integer >= 1) defaults to `1` if omitted. A `PARTICIPANT` may only create with `section: SUGGESTED` (`403` for any other section — the "suggest an item" path); a `MANAGER` may create with any section (the "add directly to the real list" path). |
| PATCH | `/groups/:groupId/grocery/:id/accept` | **MANAGER only** | — | Moves a `SUGGESTED` item to `THIS_WEEK`. `403` for a `PARTICIPANT`, `409` if the item isn't currently `SUGGESTED`. |
| PATCH | `/groups/:groupId/grocery/:id` | required (any member); field-gated by role | Any subset of `{ name, category, quantityText, section, isChecked, orderIndex, quantityCount, aisleId }` | **Asymmetric on purpose** — see "Group grocery list" below. Any member may set `isChecked`/`orderIndex`/`quantityCount`/`aisleId` (routine day-to-day list use, including "My Layout" placement and adjusting how many to buy). Only a `MANAGER` may set `name`/`category`/`quantityText`/`section` (editing what's on the list). A request from a `PARTICIPANT` that touches even one manager-only field is rejected wholesale (`403`) — nothing is partially applied. `aisleId` may be `null` (explicitly "Unsorted") or a `GroupStoreAisle` id belonging to this same group (`400` if it names an aisle in another group, or one that doesn't exist); sending it at all — including `null` — also sets `aisleManuallySet: true` on the item (see "My Layout" below). |
| DELETE | `/groups/:groupId/grocery/:id` | depends on the item's current `section` | — | `SUGGESTED`: **MANAGER, or the item's own original suggester** (rejecting a suggestion) — anyone else gets `403`. `THIS_WEEK`/`STAPLES`: **any member** (routine list maintenance — "we bought it" / "we don't need it") — no extra check. |
| GET | `/groups/:groupId/grocery/aisles` | required (member) | — | `{ aisles: [...] }` — every `GroupStoreAisle` for the group, sorted by `sortIndex`. Seeds ten starter aisles (one per `GroceryCategory`) the first time this is called for a group with none yet — see "My Layout" below. |
| POST | `/groups/:groupId/grocery/aisles` | required (any member) | `{ name }` | Creates a custom aisle, appended to the end of the walking order (`sortIndex` = current max + 1). `linkedCategory` is always `null` for a manually-created aisle — only the seeded starters get one. |
| PATCH | `/groups/:groupId/grocery/aisles/:id` | required (any member) | Any subset of `{ name, sortIndex }` | Rename and/or reposition — including a starter aisle, same as the local app. `404` if the aisle doesn't belong to this group. |
| DELETE | `/groups/:groupId/grocery/aisles/:id` | required (any member) | — | Deletes the aisle. Every `GroupGroceryItem` that was manually placed there has both `aisleId` reset to `null` **and** `aisleManuallySet` reset to `false` (not just the former) — so those items fall back to their category's default aisle again, not "explicitly Unsorted". |

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

**Recipe photos** (`photoBase64`): a recipe's user-picked photo — the iOS
`Recipe.photoData`'s raw bytes, base64-encoded — travels through this API
as plain text, stored in a `@db.Text` column rather than a Postgres `bytea`
(see the `Recipe.photoBase64` doc comment in `prisma/schema.prisma` for why:
mainly, it lets `serializeRecipe(...)` hand the value straight to
`res.json(...)` with no encode/decode step at either end). This used to be
the actual bug this field exists to fix: recipe photos were purely local
(`Recipe.photoData`, never sent anywhere), so a recipe with a photo lost it
completely the moment it was shared — the recipient's saved copy had no
image at all. Most recipes still have no photo at all (`photoBase64: null`)
— nothing changed there.

Two things worth calling out about the size/cost tradeoff of sending a photo
inline as base64 JSON rather than, say, a link to object storage: base64
costs ~33% more bytes over the wire than the raw photo, and there's no
separate thumbnail column, so a recipe with a photo is that much heavier to
fetch for every viewer, every time, not just once. This is judged
acceptable for this app's actual scale (a household/friend-group app
sharing a handful of recipes among a handful of people, not a photo-sharing
platform) given the iOS upload path already downsizes to a small JPEG
before it's ever sent — `ImageResizing.downsized(...)` caps every
locally-captured recipe photo at 800px on its long edge, JPEG-compressed,
whether or not it's ever shared, so sharing adds no new "how big can a
photo get" case beyond what on-device storage already accepted. The route
also enforces its own server-side ceiling regardless of what any particular
client sends: `photoBase64` is capped at 5MB **decoded** (not counting
base64's own ~33% inflation) — a `400` if a request's photo decodes larger
than that, or isn't valid base64 at all — see `MAX_PHOTO_BYTES_DECODED` in
routes/recipeLibrary.js. If this app ever grows well past
household/friend-group scale, revisit this with a real object store + CDN
URL and a separate thumbnail size instead of inline base64; that's a
deliberate "not yet" for v1, not an oversight.

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
this, and which way" per suggestion (`myVote`) as well as raw counts
(`upvoteCount`/`downvoteCount`) — the iOS `MealSuggestion` model needs
exactly that distinction for its own UI. A vote has a **direction**
(`UP`/`DOWN` — thumbs up or thumbs down, not upvote-only): `POST .../vote`
takes `{ direction: "UP" | "DOWN" }` and behaves like any thumbs-up/down
control — voting the same direction again retracts the vote, voting the
opposite direction switches it. See `serializeSuggestion(...)`'s own doc
comment in `routes/groupMealPlan.js` for why the response keeps
`upvoteCount`/`downvoteCount` separate rather than collapsing them into one
net score.

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
(checking something off while shopping), `orderIndex` (tidying the list),
and `quantityCount` (how many to get) are routine day-to-day *use* of an
already-decided list, open to any member — nothing about using the list
changes what's actually on it.
`name`/`category`/`quantityText`/`section` change what's on the list or how
it's organized, which is a planning decision, so those stay `MANAGER`-only,
same as adding an item directly. The route validates this field-by-field
(not route-wide): a `PARTICIPANT`'s request touching only
`isChecked`/`orderIndex`/`quantityCount` succeeds; the moment it also touches a
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

**Removed: the group-scoped standing "staples" list.** A `GroupStapleItem`
model and a `routes/groupGroceryStaples.js` router (mounted at
`.../grocery/staples`) used to live here — a household's separate standing
template list of recurring items (milk, paper towels, ...), the group
counterpart of the local `StapleItem` model. It was removed outright (model,
migration to drop the table, route file, and the iOS
`GroupStapleItem`/`GroupStaplesManagerView` side of it) per direct user
feedback that the concept added nothing useful, not merely hidden behind a
flag — it had shipped with no real accounts yet using it, so there was
nothing to migrate off of. This is unrelated to the pre-existing
`GroupGrocerySection.STAPLES` enum value on `GroupGroceryItem` (see the
table above and "Group grocery list" below), which is a tag on one specific
line already on the live list, not a standing template — that tag, and
everything that depends on it, is untouched.

**Removed: the group-shared "past groceries" catalog.** `GET
/groups/:groupId/grocery/history` — the group-scoped counterpart of the
local "Household Groceries" catalog, backed by a `GroupGroceryHistoryEntry`
table populated by a side effect inside `PATCH /groups/:groupId/grocery/:id`
(an `isChecked` `false` -> `true` transition upserted a row) — used to live
here. It was removed outright (model, migration to drop the table, the
route, the PATCH side effect, and the iOS
`GroupGroceryHistoryEntry`/`pastGroceriesSection` side of it) per direct
user feedback that a group-shared history was redundant: each member's own
personal `HistoricalGroceryItem` "Household Groceries" catalog already
does this job, is reachable from inside the group grocery screen itself
(a quick-add field directly in its "From Your Household Groceries"
section), and — unlike the group-shared version — survives correctly if
the member ever leaves the group. Same "outright removal, not just hidden"
precedent as the staples list just above.

## 9. Notifications

Phase 5, Part 3: `GET /notifications` is a single "what's waiting on my
response" feed for a notification-bell badge/screen, built entirely on the
two sources that already exist elsewhere rather than a new table or a third
notion of "notification":

```json
{
  "count": 2,
  "friendRequests": [
    { "friendshipId": "...", "from": { "id": "...", "displayName": "...", "phoneNumber": "+1..." } }
  ],
  "groupInvites": [
    {
      "id": "...",
      "group": { "id": "...", "name": "..." },
      "invitedBy": { "id": "...", "displayName": "...", "phoneNumber": "+1..." },
      "createdAt": "2026-09-13T23:54:11.485Z"
    }
  ]
}
```

- **`friendRequests`** is exactly `GET /friends`'s `incomingRequests` —
  same query (`loadFriendshipsFor` in `routes/friends.js`, exported for
  reuse rather than duplicated), same shape, same `{ friendshipId, from }`
  entries. Respond to one via the existing
  `POST /friends/:friendshipId/accept`/`decline` — this endpoint is
  read-only and doesn't add a new way to answer these.
- **`groupInvites`** is exactly `GET /invites`'s `invites` — same query
  (`listPendingGroupInvitesFor` in `routes/invites.js`, likewise exported
  for reuse), same shape, same `{ id, group, invitedBy, createdAt }`
  entries. Respond to one via `POST /invites/:inviteId/accept`/`decline`.
  Deliberately excludes a bare "become my friend" `Invite` (`groupId`
  null) — see "Invites and consent" above for why: that already surfaces
  as an ordinary `friendRequests` entry once it resolves into a
  `Friendship`, so including the underlying `Invite` row too would show
  the same pending thing twice under two different labels.
- **`count`** is just `friendRequests.length + groupInvites.length` — a
  client rendering a badge doesn't need to distinguish the two kinds of
  pending thing, only that something is pending.

A client that already knows how to render `GET /friends`'s
`incomingRequests` or `GET /invites`'s `invites` needs no new parsing logic
to also render this combined feed — it's the same two shapes, just fetched
together and counted.

### 9a. Push notifications (APNs)

Everything above is pull-based — a client has to actually open the app and
fetch `GET /notifications` to learn anything's pending. `POST
/me/device-token` (`routes/me.js`) plus `lib/apns.js` add a genuine push: a
friend request (`POST /friends/request`) or a group invite (`POST
/groups/:groupId/invite`) now also sends an APNs push to every device
token the recipient has registered, if they're already a Home Eats user
with at least one.

Registration is unauthenticated-adjacent but simple: the iOS client calls
`POST /me/device-token` with `{ "token": "<hex APNs token>" }` (any signed-in
request; see `HomeEats/Services/PushNotificationService.swift`) at launch and
right after sign-in. The row is keyed by `token` (`@unique`), not `userId` —
the same physical device/install can end up registering the same token
against a different account later (reinstall, restore to a different Apple
ID), and re-registering should just repoint that row at its new owner
rather than collide or leave two rows.

Actually **sending** a push needs four env vars, all from the Apple
Developer account this app's bundle id (`family.homeeats.app`) belongs to
— see `.env.example`: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_AUTH_KEY` (the
`.p8` Auth Key file's raw contents), `APNS_PRODUCTION`. Without them,
`lib/apns.js`'s `sendPush` silently no-ops (same "lazily constructed,
returns null when unconfigured" shape as `twilioClient()`/
`anthropicClient()` elsewhere in this file) — device-token registration and
every other route keep working normally either way, there's just nothing
on the other end to actually deliver a push until these are set.

## 10. Personal restaurant library

A signed-in user's own saved restaurants — added so this survives a
local-store reset and is recoverable across devices/reinstalls, the direct
fix for a real incident where a missing iOS SwiftData migration default
wiped a user's entire local store (see `prisma/schema.prisma`'s own doc
comment on the `Restaurant` model, and the iOS `HomeEatsApp.swift`'s on
`ModelContainer` creation, for the full story). Routes live in
`routes/restaurants.js`, mounted at `/restaurants/library` — deliberately
NOT bare `/restaurants`, which is already the unauthenticated Google-Places-
proxy search API (`/restaurants/search`, `/restaurants/search-natural`,
`/restaurants/photo`, `/restaurants/details`) registered directly on `app`
in `index.js`. Every route here requires auth. No sharing/visibility
concept at all, unlike recipe-library — every restaurant here is simply
"the caller's own."

| Method | Path | Auth | Body | Notes |
|---|---|---|---|---|
| GET | `/restaurants/library` | required | — | `{ restaurants: [...] }` — every restaurant the caller owns, oldest first. No pagination — a household's library is small enough to just send it all, same call `GET /recipe-library/mine` makes. |
| POST | `/restaurants/library` | required | `{ name, cuisine?, priceRange?, rating?, notes?, websiteUrl?, address?, isFavorite?, googlePhotoNames?, googlePlaceId?, latitude?, longitude? }` | Creates a restaurant owned by the caller. Returns `{ restaurant }`. |
| PATCH | `/restaurants/library/:id` | required, owner only | Any subset of the same fields as `POST` (all optional, `name` included) | `404` if the id doesn't exist or isn't the caller's. The iOS client always sends every field on every call (its own full current state, `null` for anything it has no value for) rather than a genuine partial diff — see `PersonalLibrarySyncService`'s own doc comment for why — but the schema itself accepts a real subset if a future caller wants one. |
| DELETE | `/restaurants/library/:id` | required, owner only | — | `404` if the id doesn't exist or isn't the caller's, otherwise `204`. |

The iOS sync design (`PersonalLibrarySyncService`) is deliberately simpler
than the group meal-plan/grocery sync engine: a personal library has
exactly one writer (the account itself), so there's no multi-writer
conflict story to protect against — every sync pass just re-sends each
local restaurant/recipe's full current state (create if it has no backend
id yet, otherwise `PATCH`) and pulls down any backend row with no local
match by id. See that type's own doc comment for the full reasoning,
including why deletes are handled immediately/inline rather than through
this same pass.

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
- `/cities/search` and `/cities/:placeID` (see "City search" above) are two
  separate billed Google calls per selection, same as `/restaurants/search`
  and `/restaurants/details` — Autocomplete fires on debounced keystrokes
  while typing, Place Details fires once when a suggestion is actually
  tapped, not on every keystroke.
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
  see "Group roles" above), including promote/demote and multiple managers
  per group as of Phase 5.
