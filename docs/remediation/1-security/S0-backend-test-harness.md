# S0 — Backend test harness

| | |
|---|---|
| Phase | 1 (prerequisite for security fixes) |
| Severity | Prerequisite |
| Depends on | — |
| Size | S |
| Touches | `backend/index.js`, new `backend/app.js`, `backend/package.json`, new `backend/test/` |

## Problem

The backend has no tests and no `npm test` script (`backend/package.json`).
`backend/index.js` builds the Express app *and* calls `prisma.$connect()` and
`app.listen()` at module load, so nothing can import the app without a
database and an open port. Every security plan after this one needs a way to
prove its fix works.

## Goal

A zero-dependency test setup that:
- runs pure unit tests with no database, and
- runs HTTP-level route tests against the real Express app when a test
  Postgres is available, and skips them cleanly when it isn't.

## Acceptance criteria

- [ ] `cd backend && npm test` runs and passes with **no** `DATABASE_URL` set
      (integration tests report as skipped, not failed).
- [ ] `TEST_DATABASE_URL=postgres://... npm test` also runs the integration
      tests and they pass.
- [ ] `node index.js` behaves exactly as before (connects to the database,
      then listens on `PORT`).
- [ ] No new runtime dependencies. Dev dependencies are allowed but not
      required (Node's built-in `node:test` and global `fetch` are enough).

## Steps

1. **Split the app from the server.**
   - Create `backend/app.js`. Move everything from `backend/index.js` that
     builds the app (the `express()` call, `app.set`, middleware, every route
     registration, and the final error handler) into it, ending with
     `module.exports = { app };`.
   - Reduce `backend/index.js` to: require `./app`, require `./lib/prisma`,
     then the existing `prisma.$connect().then(() => app.listen(PORT, ...))`
     block, unchanged.
   - Don't change any route behavior in this step. Use `git diff --stat` to
     confirm it's a pure move, and keep the diff easy to review.
2. **Add the test script.** In `backend/package.json` add
   `"test": "node --test test/"`. Node ≥ 18 is already required by
   `engines`; the CI in R3 should use Node 20+.
3. **Add unit tests** in `backend/test/unit/`:
   - `rateLimit.test.js`: allows `max` hits, blocks hit `max + 1`, resets
     after `windowMs` (use small windows, e.g. 50 ms, and `await` a timer).
   - `phone.test.js`: `E164_PHONE_REGEX` accepts `+14155551234`, rejects
     `14155551234`, `+0123456`, and `+1 415 555 1234`.
   - `twilio.test.js`: `inviteSMSBody` always ends with
     `"Reply STOP to opt out."`, with and without `APP_DOWNLOAD_URL`.
4. **Add an integration test helper** at `backend/test/helpers/server.js`:
   - `startTestServer()`: if `process.env.TEST_DATABASE_URL` is unset, return
     `null`. Otherwise set `process.env.DATABASE_URL = TEST_DATABASE_URL` and
     `process.env.JWT_SECRET` to a fixed test value **before** requiring
     `../../app`, call `app.listen(0)`, and return `{ baseURL, close }`.
   - `signTestToken(userId, tokenVersion = 0)`: signs a JWT with the test
     secret, same payload shape as `signToken` in `routes/auth.js`.
   - `createTestUser(overrides)`: creates a `User` row through
     `lib/prisma` with a random E.164 phone number.
   - `resetDatabase()`: truncates all tables (Postgres
     `TRUNCATE ... RESTART IDENTITY CASCADE` over every Prisma model table).
5. **Add one integration test** to prove the harness works:
   `backend/test/integration/me.test.js`. Use `t.skip()` when
   `startTestServer()` returns `null`. Cover:
   - `GET /me` with no token → 401
   - `GET /me` with a valid token → 200 and the user's id
   - `GET /me` with a token whose `tokenVersion` is behind the user's → 401
6. **Document it** in `backend/README.md` under a new "Running tests"
   heading: how to run unit tests only, and how to point
   `TEST_DATABASE_URL` at a throwaway local Postgres, e.g.
   `docker run -e POSTGRES_PASSWORD=pw -p 5433:5432 postgres:16`, then
   `npx prisma migrate deploy` with `DATABASE_URL` pointed at it.

## Verification

- `npm test` with no environment → unit tests pass, integration tests skipped.
- With a local Postgres → all pass.
- `node --check index.js app.js`.

## Out of scope

- Wiring tests into GitHub Actions (R3).
- Refactoring `index.js` beyond the app/server split (R4).
