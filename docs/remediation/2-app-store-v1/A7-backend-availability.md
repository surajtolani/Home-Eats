# A7 — Backend availability for App Review and launch

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | Rejection risk (Guideline 2.1: app completeness, crashes and errors during review) |
| Depends on | — |
| Size | S (mostly [HUMAN] plus small code) |
| Touches | `backend/index.js` (`/health`), `HomeEats/Services/AccountsAPIClient.swift`, `HomeEats/Views/Account/AccountSignInView.swift` |

## Problem

The whole app depends on one Render web service
(`https://home-eats-uqbp.onrender.com`, hardcoded in 5 Swift files). On
Render's free tier, services spin down after inactivity, and the first
request takes about 30–60 s, which can exceed the app's request timeout.
If a reviewer opens the app, the first sign-in request hangs or fails, and
the review is rejected. `/health` also reports configuration but never
checks that the database is reachable.

## Acceptance criteria

- [ ] **[HUMAN]** The Render service runs on a paid instance type (no
      spin-down), with health check path `/health/ready` and zero-downtime
      deploys.
- [ ] `GET /health/ready` runs `SELECT 1` through Prisma with a 2 s timeout
      and returns 200 `{ ok: true }` or 503. Leave `/health` as is (the
      configuration booleans are useful for humans).
- [ ] `/health` stops listing *which* secrets are missing in production:
      when `NODE_ENV=production`, it returns only `{ ok: true }` unless the
      request has `?verbose=1` **and** a header
      `x-health-token: $HEALTH_TOKEN`. This avoids publicly advertising
      which integrations are down. Add `HEALTH_TOKEN` to `.env.example`.
- [ ] iOS: the sign-in request (`requestCode`) uses a 30 s timeout. If it
      fails because of a timeout or connection error, the sign-in screen
      shows "Couldn't reach Home Eats. Check your connection and try again."
      with a Retry button instead of a generic error. Apply the same
      friendly error to `verifyCode`.
- [ ] iOS: on launch, fire a background, fire-and-forget
      `GET /health/ready` to warm the server while the user types their
      number. No UI depends on it.

## Steps

1. Backend: add `/health/ready`, and the verbose gating on `/health`.
2. iOS: in `AccountsAPIClient`, make sure the request builder sets
   `timeoutInterval` (default 30). Map `URLError.timedOut`,
   `.cannotConnectToHost`, and `.notConnectedToInternet` to a new
   `AccountsAPIError.unreachable` case. Show the friendly message in
   `AccountSignInView.swift`.
3. iOS: add `AccountsAPIClient.warmUp()` and call it from `HomeEatsApp` or
   the root view's `.task`.
4. README deploy section: document the instance type requirement and the
   health check path.
5. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- Render dashboard: upgrade the instance type, set the health check path to
  `/health/ready`, and confirm the Postgres plan has backups enabled.
- Confirm all environment variables are set for production:
  `APNS_PRODUCTION=true` for TestFlight and App Store builds,
  `APP_DOWNLOAD_URL`, and the review login variables from A2.
- Right before submitting, run through the review account flow from a
  device on cellular.
