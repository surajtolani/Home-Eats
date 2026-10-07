# R7 — Observability and security audit log

| | |
|---|---|
| Phase | 3 — Post-1.0 |
| Severity | Ops |
| Depends on | S6 (redaction helpers) |
| Size | M |
| Touches | new `backend/lib/logger.js`, `backend/prisma/schema.prisma` + migration, auth, friends, groups, and recipe routes |

## Problem

- Logging is free-form `console.log`/`console.error` lines. Investigating
  the "unprompted SMS codes" incident (see the comments in `routes/auth.js`)
  relied on grepping Render's log stream, which has limited retention.
- Nothing records security-relevant events (sign-ins, sign-out-all, account
  deletion, bans, blocks) anywhere queryable.
- No error tracking on the backend or in the iOS app (crashes are only
  visible through Xcode Organizer).

## Acceptance criteria

- [ ] `lib/logger.js`: a structured JSON logger using `pino` (new
      dependency) with a redaction config for `phoneNumber`, `authorization`,
      `token`, `code`, and `imageBase64`. Every `console.*` call in `backend/`
      is replaced.
- [ ] A request id middleware: generates `x-request-id`, includes it in
      every log line, and returns it in the response header.
- [ ] `SecurityEvent` table: `{ id, userId?, type, ip, userAgent, metadata Json, createdAt }`,
      with types `SIGN_IN`, `SIGN_IN_FAILED`, `SIGN_OUT_ALL`,
      `ACCOUNT_DELETED`, `REVIEW_LOGIN`, `BANNED`, `BLOCKED`, and
      `REPORT_FILED`. Written from the relevant routes. Rows older than 180
      days are purged daily by the same sweep pattern as S1.
- [ ] Privacy policy (A3) updated to mention the security event log and its
      180-day retention.
- [ ] **[HUMAN]** choice of error tracking (e.g. Sentry) for backend and iOS.
      If chosen, add the SDK, scrub personal data in `beforeSend`, and add it
      to the privacy manifest's data types (Crash Data, Performance Data).
