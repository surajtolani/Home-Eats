# Home Eats backend

An Express server with two jobs. First, a proxy in front of the Google
Places API and the Claude API, so the real API keys live only here (as
environment variables) and never ship inside the iOS app — see
`GooglePlacesService.swift` and `ClaudeRecipeService.swift` in the iOS app
for the client side of that. Second — new as of this feature — the real
backend for accounts, friends, and groups: phone number + SMS sign-in, a
friends list, and Splitwise-style groups, backed by Postgres. See "Accounts,
friends, and groups" below.

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
npx prisma migrate deploy
```

This creates every table in `prisma/schema.prisma` (`User`, `Friendship`,
`Group`, `GroupMembership`, `Invite`). Run it again after pulling any future
change to `prisma/schema.prisma`/`prisma/migrations/` — it's safe to run
repeatedly, it only applies migrations that haven't run yet. (`prisma
migrate dev` also works locally if you want an interactive flow that can
generate new migrations as the schema evolves; `migrate deploy` is the
non-interactive one to use in production and in this initial setup.)

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
```

## 3. Deploy it (Render, same as the pattern used elsewhere)

1. [render.com](https://render.com) → New → Web Service → connect this
   GitHub repo.
2. **Root Directory**: `backend`
3. **Build Command**: `npm install && npx prisma migrate deploy`
   — runs any not-yet-applied migrations as part of every deploy, so the
   database schema always matches the code being deployed. (Render Postgres
   works fine here; so does any external Postgres reachable from Render.)
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
full data model and the reasoning behind each table. This is backend-only
so far — the iOS app doesn't call any of this yet; that's a later pass once
this API has settled.

Every route below except the two `/auth/*` ones requires
`Authorization: Bearer <token>` (the token `POST /auth/verify-code`
returns). A missing/invalid/expired token gets a `401`. Every error
response has the shape `{ "error": "..." }`.

| Method | Path | Auth | Body | Notes |
|---|---|---|---|---|
| POST | `/auth/request-code` | none | `{ phoneNumber }` | Sends an SMS code via Twilio Verify. `phoneNumber` must be E.164 (e.g. `+14155551234`). |
| POST | `/auth/verify-code` | none | `{ phoneNumber, code }` | Checks the code; finds-or-creates the `User`, resolves any pending `Invite`s for that number, and returns `{ token, user }`. |
| GET | `/me` | required | — | Returns `{ user: { id, phoneNumber, displayName, createdAt } }` for the caller. |
| PATCH | `/me` | required | `{ displayName }` | Sets the caller's display name. Returns the updated `{ user }`. |
| POST | `/friends/request` | required | `{ phoneNumber }` | Sends a friend request. If that number belongs to an existing user, creates/updates a `Friendship`; if a request in the other direction was already pending, this accepts it instead. If the number isn't a user yet, creates an `Invite` (no group) that auto-resolves into an accepted friendship when they sign up. `409` if already friends or already pending. |
| POST | `/friends/:friendshipId/accept` | required | — | Recipient only; `403` otherwise, `409` if not `PENDING`. |
| POST | `/friends/:friendshipId/decline` | required | — | Recipient only; same error shape as accept. |
| GET | `/friends` | required | — | `{ friends: [...], incomingRequests: [...], outgoingRequests: [...] }` — accepted friends, plus separate pending lists for requests you've received and sent. |
| POST | `/groups` | required | `{ name, memberUserIds?: string[] }` | Creates a group with the caller as a member, plus any `memberUserIds` — each must already be an accepted friend of the caller (`400` otherwise, so you can't add a stranger's id). Returns `{ group }` including the member list. |
| GET | `/groups` | required | — | `{ groups: [...] }` — every group the caller belongs to (a lightweight list; use the next route for members). |
| GET | `/groups/:groupId` | required | — | `{ group }` with the full member list, phone numbers included (safe here — everyone returned is a fellow member of this same group). `403` if the caller isn't a member. |
| POST | `/groups/:groupId/invite` | required | `{ userId }` **or** `{ phoneNumber }` | Only current members may invite. `userId` (or a `phoneNumber` that turns out to belong to an existing user) must be an accepted friend of the caller — same anti-stranger rule as group creation — and is added as a member directly. A `phoneNumber` that isn't a user yet creates an `Invite` with this `groupId`, which turns into membership (and a friendship with the inviter) on signup. `409` if already a member / already invited. |
| DELETE | `/groups/:groupId/members/:userId` | required | — | Leave (pass your own id) or remove another member — v1 has no admin role, any current member can remove any other. `403` if the caller isn't a member, `404` if the target isn't. |

## Notes

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
- There's no delete-account, remove-phone-number, or admin-role system yet
  (see the `DELETE /groups/:groupId/members/:userId` note above — v1 keeps
  group membership deliberately simple/permissive). Those are reasonable
  things to add once real usage shows they're needed.
