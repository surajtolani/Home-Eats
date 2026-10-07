# A10 — Backend robustness and database operations

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum (production readiness) |
| Severity | Outage and data-loss risk |
| Depends on | S0 (tests). Coordinate with A7 (availability) and R4 (if `index.js` is already split, apply this to the new files). |
| Size | M |
| Touches | `backend/index.js` / `app.js`, `backend/lib/prisma.js`, `backend/lib/apns.js`, `backend/routes/*.js`, `backend/README.md` deploy section |

## Current state (reviewed October 2026)

- **Database:** PostgreSQL, accessed only through Prisma ORM 6.19.3
  (`lib/prisma.js`, one shared `PrismaClient`). 22 migrations in
  `prisma/migrations/`, applied by the Render build command
  `npm install && npx prisma generate && npx prisma migrate deploy`.
- **Hosting:** the API is a Render web service
  (`home-eats-uqbp.onrender.com`). The repo doesn't say where Postgres is.
  The README suggests Render Postgres but allows any provider. There's no
  `render.yaml`, so the infrastructure isn't in code.
- **SQL injection:** low risk. There's no `$queryRaw`, `$executeRaw`, or
  `*Unsafe` anywhere. Every route that touches Prisma validates its body
  with Zod first (so no `{ "not": ... }`-style operator injection is
  possible), and route params only reach `where: { id }` as strings. **Keep
  it that way:** S1 introduces the first raw query, and it **must** use the
  tagged-template `prisma.$queryRaw\`...\`` form with `${}` parameters,
  never `$queryRawUnsafe` or string concatenation.

## Problems

1. **No graceful shutdown.** Nothing handles `SIGTERM`, so on every Render
   deploy or restart, in-flight requests (including multi-step
   transactions) are cut off and Prisma connections aren't closed.
2. **Process crash on any unhandled rejection.** The 10 proxy routes in
   `index.js` (lines 619–1242) are plain `async (req, res)` handlers that
   don't go through `asyncHandler`. They rely on their own `try/catch`
   blocks, so any throw outside those blocks becomes an unhandled
   rejection, which **terminates the Node process** on Node ≥ 15. There's no
   `process.on('unhandledRejection')` safety net or logging.
3. **No outbound timeouts.** Calls to Google Places, Geocoding, and Custom
   Search use `fetch` with no timeout (`index.js:564, 599, 816, 859, 955,
   1028, 1191`). The Anthropic SDK's default timeout is about 10 minutes,
   with retries. A slow upstream holds sockets and memory on the single
   instance.
4. **No database query or statement timeout and no pool settings.** A
   stuck query or lock (for example, in a Serializable transaction in
   `friends.js`) can hang a request indefinitely. Prisma's default pool
   size depends on the number of CPUs, and the database's connection limit
   isn't considered.
5. **Unique-constraint races return 500.** Several routes check "does it
   exist?" and then create (shares, invites, aisles). A concurrent duplicate
   hits a unique constraint and becomes a generic 500. No handler maps
   Prisma `P2002` → 409 or `P2025` → 404.
6. **Unbounded queries.** 25 `findMany` calls, none with `take`. For
   example, `GET /groups/:id/meal-plan` returns every planned meal and
   suggestion the group has ever had (`groupMealPlan.js:211`). Response size
   and query time grow forever. Recipe lists are covered by R1; this plan
   covers the rest.
7. **Deploy-time migration hazards.**
   - The build uses `npm install` (not `npm ci`), so production can resolve
     different dependency versions than `package-lock.json`.
   - `migrate deploy` runs while the **old** code is still serving. A
     migration that drops or renames a column breaks the old instance
     mid-deploy. There are already four `drop_*` migrations in history.
     Nothing documents an expand/contract rule.
8. **Backups and plan unknown.** If the database is on Render's **free**
   Postgres tier, it has no backups and the instance **expires** after a
   limited period. Check what the current plan does.

## Acceptance criteria

- [ ] **Graceful shutdown:** `index.js` keeps the `server` returned by
      `app.listen`. On `SIGTERM` or `SIGINT` it stops accepting
      connections (`server.close`), waits up to 10 s for in-flight requests,
      then calls `prisma.$disconnect()` and exits 0. A second signal forces
      exit.
- [ ] **Crash safety:** every route handler in `index.js` is wrapped in
      `asyncHandler`. `process.on('unhandledRejection')` logs the error and
      keeps the process alive. `process.on('uncaughtException')` logs it
      and exits 1, so Render restarts the service. Exiting is correct for
      sync exceptions.
- [ ] **Outbound timeouts:** a helper `fetchWithTimeout(url, opts, ms = 8000)`
      in `lib/http.js` using `AbortSignal.timeout(ms)`, used for every Google
      call. The Anthropic client is constructed as
      `new Anthropic({ timeout: 60_000, maxRetries: 1 })`. A timeout → 504
      `{ error: "Upstream service timed out." }`.
- [ ] **Server timeouts:** `server.requestTimeout = 90_000` and
      `server.headersTimeout = 65_000` (Node HTTP server settings).
- [ ] **DB timeouts and pool:** README documents adding
      `?connection_limit=10&pool_timeout=10` (sized to the database plan's
      connection limit) and `&sslmode=require` if using an external
      connection string. Every interactive `prisma.$transaction(fn, ...)` gets
      `{ timeout: 10_000, maxWait: 5_000 }`. Add a Postgres
      `statement_timeout` of 15 s for the app role. That's
      `ALTER ROLE <app_user> SET statement_timeout = '15s'` — a
      **[HUMAN]**/ops step, documented in the README. An app-side migration
      is the wrong place for it.
- [ ] **Prisma errors → HTTP:** the final error handler maps
      `Prisma.PrismaClientKnownRequestError` `P2002` → 409
      `{ error: "That already exists." }`, `P2025` → 404, and `P2034`
      (serialization) → 409 "Please retry". Everything else stays 500 with no
      detail leaked.
- [ ] **Bounded reads:**
      - `GET /groups/:groupId/meal-plan` accepts `?from=YYYY-MM-DD&to=YYYY-MM-DD`,
        defaulting to 30 days back through 90 days ahead, with a maximum
        range of 400 days. Check what the iOS client
        (`AccountsAPIClient.getGroupMealPlan`, `GroupSyncService`) expects
        before changing defaults, and make the iOS change in the same PR if
        needed.
      - Notifications, invites, and friends lists get `take: 200`, newest
        first.
      - Grocery lists get `take: 1000`.
      - Meal history and the restaurants library get `take: 1000`.
      - Leave a short comment at each cap.
- [ ] **Deploy safety:** README build command becomes
      `npm ci && npx prisma generate && npx prisma migrate deploy`. A new
      "Schema change rules" section says:
      1. Additive migrations only in the same deploy as the code that uses
         them.
      2. To drop or rename a column: ship code that stops using it first,
         then drop it in a later deploy.
      3. Never edit an applied migration.
- [ ] **Infrastructure as code:** add `render.yaml` describing the web
      service (root `backend`, build and start commands, health check path
      `/health/ready` from A7, `autoDeploy` on the default branch, env var
      **names** only with `sync: false`) and the database. A human confirms
      the plan names match what's actually provisioned.
- [ ] **Tests:** unique-violation → 409 (two concurrent identical
      `POST /recipe-library/:id/share`); a meal-plan date-range filter test;
      a unit test for `fetchWithTimeout` aborting against a local server that
      never responds.

## [HUMAN] steps

- Find out where Postgres lives. In Render → web service → Environment, look
  at the `DATABASE_URL` host. `dpg-…` hosts are Render Postgres; anything
  else is an external provider.
- If it's Render **free** Postgres, upgrade to a paid plan before launch
  (paid plans include daily backups and point-in-time recovery, and don't
  expire). On any provider, confirm automated backups are on, and **do one
  restore drill** into a scratch database before submitting.
- Confirm the database and web service are in the same region, and that the
  web service uses the **internal** connection string.
- Run `ALTER ROLE ... SET statement_timeout = '15s'` for the app's database
  user.
- Rotate the database password if it has ever been pasted anywhere outside
  Render's environment settings.

## Out of scope

- Moving photos out of Postgres and paginating recipe lists (R1).
- Read replicas, multiple instances, and connection poolers like PgBouncer.
  Revisit once S1 has made multiple instances safe.
