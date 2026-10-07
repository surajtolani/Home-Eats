# S1 — Durable rate limiting

| | |
|---|---|
| Phase | 1 — Security |
| Severity | High (every other abuse control depends on it) |
| Depends on | S0 |
| Size | M |
| Touches | `backend/lib/rateLimit.js`, `backend/prisma/schema.prisma` + new migration, `backend/routes/auth.js`, `backend/app.js` (or `index.js` before S0) |

## Problem

`backend/lib/rateLimit.js` keeps counters in a process-local `Map`. They reset
on every deploy or restart, and if Render ever runs more than one instance,
each one has its own counters. Today these limiters are the only thing
protecting:
- `POST /auth/request-code` (each call is a paid Twilio Verify SMS),
- `POST /auth/verify-code` (brute force and lockout of someone else's sign-in),
- the paid Google and Anthropic proxy routes,
- and, after S2, SMS invites.

The file's own comment says it's "a mitigation, not a complete fix".

## Goal

A rate limiter whose state lives in Postgres, so limits survive restarts and
are shared across instances. It keeps the same `check(key)` call shape so call
sites barely change. It needs no new infrastructure because Postgres already
exists.

## Acceptance criteria

- [ ] New Prisma model `RateLimitBucket` and a migration that creates it.
- [ ] `createRateLimiter({ name, windowMs, max })` returns
      `{ check(key) → Promise<{ limited, retryAfterMs? }> }`, backed by
      Postgres. `name` namespaces limiters that share a key (for example
      `request-code:phone` vs `verify-code:phone`).
- [ ] Each check is a **single atomic SQL statement**, so two concurrent
      requests can't both slip under the limit.
- [ ] Every existing limiter (auth and proxy routes) uses the durable
      limiter.
- [ ] Old rows get cleaned up.
- [ ] If the database errors during a check: **fail closed** for
      `/auth/request-code`, `/auth/verify-code`, and SMS invites (return
      503), and **fail open** for everything else (log and allow). This is
      configurable per limiter with `failClosed: true`.
- [ ] Integration tests: hitting `max + 1` returns 429; a new limiter
      instance with the same `name` (simulating a restart) still sees the
      earlier hits.

## Steps

1. **Schema.** Add to `backend/prisma/schema.prisma`:
   ```prisma
   // Fixed-window rate-limit counters, shared across restarts and instances.
   model RateLimitBucket {
     key         String   // "<limiter name>:<caller key>"
     windowStart DateTime
     count       Int      @default(0)
     expiresAt   DateTime

     @@id([key, windowStart])
     @@index([expiresAt])
   }
   ```
   Then create the migration (see the conventions in the README).
2. **Rewrite `lib/rateLimit.js`.**
   - `windowStart = new Date(Math.floor(Date.now() / windowMs) * windowMs)`.
   - Make one atomic upsert-and-increment with `prisma.$queryRaw`:
     ```sql
     INSERT INTO "RateLimitBucket" ("key","windowStart","count","expiresAt")
     VALUES ($1, $2, 1, $3)
     ON CONFLICT ("key","windowStart")
     DO UPDATE SET "count" = "RateLimitBucket"."count" + 1
     RETURNING "count";
     ```
     Set `expiresAt = windowStart + windowMs`. `limited = count > max`, and
     `retryAfterMs = expiresAt - now`.
   - Note this counts blocked attempts too. That's intended: a caller
     hammering the endpoint stays blocked.
   - Wrap the query in try/catch and apply the `failClosed` rule. Return
     `{ limited: true, retryAfterMs: 60_000, error: true }` when failing
     closed.
   - Keep a sweep: `setInterval(..., 10 min).unref()` that runs
     `DELETE FROM "RateLimitBucket" WHERE "expiresAt" < now() - interval '1 hour'`.
     Start it lazily on first `check` so tests and imports don't open timers.
3. **Update call sites.** `check` is now async.
   - `routes/auth.js`: `await` each limiter. Give each one a distinct `name`.
     Set `failClosed: true` on all five. Keep the existing "check all
     limiters, don't short-circuit" behavior by using `Promise.all`.
   - `rateLimited(limiter, keyFn)` in `index.js`/`app.js`: make the
     middleware async (wrap with `asyncHandler`) and `await
     limiter.check(...)`. Add a `Retry-After` header (seconds) on 429.
4. **Tests** in `backend/test/integration/rateLimit.test.js` (skips without
   `TEST_DATABASE_URL`):
   - 3 checks with `max: 2` → the third is limited.
   - Two limiter instances with the same name share state.
   - 20 concurrent checks with `max: 5` → exactly 5 are allowed.
   - Different `name`s with the same key don't interfere.
5. **Docs.** Replace the "in-memory, resets on deploy" explanation in
   `backend/README.md` and the comments in `routes/auth.js` that rely on it.

## Verification

- `npm test` with `TEST_DATABASE_URL` set.
- Manual: run the server locally, call `POST /auth/request-code` twice in a
  row for the same number → the second call returns 429. Restart the server
  and call again within 60 s → still 429.

## Out of scope

- Redis or any new infrastructure.
- Changing the actual limit values (other plans tune their own limits).
