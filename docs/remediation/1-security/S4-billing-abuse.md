# S4 — Billing abuse: authenticate image routes, cap inputs and body sizes

| | |
|---|---|
| Phase | 1 — Security |
| Severity | Medium (direct cost exposure on Google and Anthropic bills) |
| Depends on | S1 (durable limits), S3 (image proxy refactor) |
| Size | L (backend + iOS) |
| Touches | `backend/index.js`/`app.js`, `HomeEats/Services/GooglePlacesService.swift`, `HomeEats/Services/RecipeImageProxy.swift`, `HomeEats/Services/AccountsAPIClient.swift`, new `HomeEats/Views/Shared/RemoteImage.swift`, the 5 views that use `AsyncImage` |

## Problem

1. **Two paid or bandwidth-heavy routes need no login** because SwiftUI's
   `AsyncImage` can't send an `Authorization` header:
   - `GET /restaurants/photo` (`index.js:799`): every call is a paid Google
     Places Photo request. It's limited to 600 per hour **per IP**, which
     rotating IPs gets around.
   - `GET /recipes/image-proxy` (`index.js:1242`): a free 8 MB-per-request
     proxy for anyone.
2. **AI routes don't cap input size.**
   - `POST /recipes/extract`: `notesText` has no limit, `imageBase64` is only
     bounded by the global body limit, and `mediaType` isn't validated.
   - `POST /recipes/recommend`: `ingredients[]` and `excludeTitles[]` have no
     length or count limits, and items aren't type-checked.
   - `POST /restaurants/search-natural`: `query` and `fallbackLocationText`
     have no limit, and `lat`/`lng` aren't range-checked.

   Each request can be made as large as possible to maximize token spend.
3. **Global JSON body limit is 15 MB** (`index.js:62`) for every route,
   including ones that only need a few KB. That's memory and CPU pressure on
   a single instance.
4. Proxy limits are hourly only. There's no per-user **daily** ceiling on
   paid calls, and no global daily circuit breaker.

## Goal

Every route that costs money requires a signed-in user and has bounded
input, and spend per user per day is capped.

## Acceptance criteria

- [ ] `GET /restaurants/photo` and `GET /recipes/image-proxy` require a
      Bearer token (`requireAuth`) and are rate-limited **per user** (S1
      limiter).
- [ ] The iOS app loads both through a new authenticated image view, and no
      `AsyncImage` points at the backend anymore.
- [ ] Zod schemas on `/recipes/extract`, `/recipes/recommend`,
      `/restaurants/search-natural`, `/restaurants/search`, `/cities/search`,
      and `/recipes/web-search` with the limits listed in step 3. Oversized
      input returns 400 **before** any paid call.
- [ ] The global `express.json` limit is **100 KB**. Larger limits apply only
      to routes that accept photos: `/recipes/extract` (8 MB), and
      `POST`/`PATCH /recipe-library` (8 MB, since the 5 MB decoded photo cap
      is about 6.7 MB as base64).
- [ ] Per-user daily caps on every AI route, plus a global daily AI request
      cap from `AI_DAILY_GLOBAL_MAX` (default 2000). Over the cap → 429 with
      a friendly message.
- [ ] Tests for auth on the image routes, the 400s on oversized input, and
      413 on an oversized body for a small route.

## Steps

### Backend

1. **Auth on image routes.** Add `requireAuth` and switch the limiters to
   `byUserId` on both routes. Delete the now-stale "deliberately
   unauthenticated" comments. Set `Cache-Control: private, max-age=86400`
   (not `public`) since responses are now per-user authenticated.
2. **Body limits.** Replace `app.use(express.json({ limit: "15mb" }))` with
   `app.use(express.json({ limit: "100kb" }))`, and register
   `express.json({ limit: "8mb" })` as route-level middleware **before** the
   global parser runs for those paths. The simplest way: define
   `const largeJson = express.json({ limit: "8mb" })` and mount
   `app.use(["/recipes/extract", "/recipe-library"], largeJson)` above the
   global `app.use(express.json(...))`. Express's JSON parser skips bodies
   that are already parsed. Make sure the 413 from body-parser returns JSON
   through the error handler (`err.type === 'entity.too.large'` → 413
   `{ error: "Request too large." }`).
3. **Input schemas** (Zod, `safeParse`, 400 with the first issue message):
   - `/recipes/extract`: `notesText` string ≤ 10,000 characters, optional;
     `imageBase64` base64 string ≤ 7,000,000 characters, optional;
     `mediaType` in `["image/jpeg","image/png","image/webp","image/gif"]`,
     default `image/jpeg`; at least one of the two content fields required.
   - `/recipes/recommend`: `ingredients` array ≤ 40 of strings 1–80
     characters; `excludeTitles` array ≤ 40 of strings 1–200 characters.
   - `/restaurants/search-natural`: `query` 1–300 characters;
     `fallbackLocationText` ≤ 200 characters, nullable; `lat` −90..90 and
     `lng` −180..180, optional.
   - `/restaurants/search` and `/cities/search`: `q` 1–200 characters.
     `/recipes/web-search`: `q` 1–200 characters.
4. **Daily caps** (S1 limiters, keyed by `req.userId`, 24 h window), stacked
   after the existing hourly ones: extract 50/day, recommend 50/day,
   search-natural 100/day, and photo 1000/day. Global `ai:global` keyed by
   `"all"` with `AI_DAILY_GLOBAL_MAX` (24 h), applied to the three AI routes.
   Add the new environment variable to `.env.example`.
5. **Tests** (integration, skipped without a database): unauthenticated
   `GET /restaurants/photo` → 401; `notesText` of 10,001 characters → 400
   and Anthropic is never called (stub the client by temporarily replacing
   `ANTHROPIC_API_KEY` with empty → the route would 500, so assert 400
   comes first); a 200 KB body to `PATCH /me` → 413.

### iOS

6. **Authenticated image loader.** Create
   `HomeEats/Views/Shared/RemoteImage.swift`:
   - A `RemoteImage<Placeholder: View>` view taking `url: URL?`, a content
     closure `(Image) -> some View`, and a placeholder.
   - Loads with `URLSession.shared` and a `URLRequest` carrying
     `Authorization: Bearer <KeychainTokenStore.readToken()>`.
   - In-memory `NSCache<NSURL, UIImage>` (a static shared instance,
     `countLimit` ≈ 200) and `URLCache` for disk caching through the
     request's default cache policy.
   - Cancels in `.task(id: url)` when the view disappears or the URL changes.
   - On 401, do **not** sign out (`AccountsAPIClient` already owns that);
     just show the placeholder.
7. **Swap call sites.** Replace `AsyncImage` that points at the backend
   (`GooglePlacesService.photoURL(...)` or `RecipeImageProxy.url(for:)`) in:
   `Views/Recipes/RecipeThumbnail.swift`, `Views/Recipes/RecipesHomeView.swift`,
   `Views/Account/GroupRecipePreviewView.swift`,
   `Views/Restaurants/RestaurantDetailView.swift`, and
   `Views/Restaurants/RestaurantListView.swift`. Run
   `grep -rn AsyncImage HomeEats` and handle every hit. If an `AsyncImage`
   loads a non-backend URL (for example web search `thumbnailURL`), route it
   through `RecipeImageProxy` plus `RemoteImage` too, for the same privacy
   reason the proxy exists. Update the doc comments in
   `GooglePlacesService.photoURL` and `RecipeImageProxy` that say the URL is
   "suitable for handing straight to AsyncImage".
8. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- Google Cloud Console: put **API restrictions** on both keys (Places key →
  Places API (New) + Geocoding only; Custom Search key → Custom Search only),
  and set **quota caps** per API per day plus a **budget alert**.
- Anthropic Console: set a monthly **spend limit** on the workspace that owns
  `ANTHROPIC_API_KEY`.

## Out of scope

- Moving images to object storage or a CDN (R1).
- Choosing cheaper models (R5).
