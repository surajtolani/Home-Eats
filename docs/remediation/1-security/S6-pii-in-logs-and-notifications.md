# S6 — Phone numbers in logs, pushes, and SMS

| | |
|---|---|
| Phase | 1 — Security |
| Severity | Low (privacy) |
| Depends on | — |
| Size | S |
| Touches | `backend/routes/auth.js`, `backend/routes/friends.js`, `backend/routes/groups.js`, `backend/routes/invites.js`, `backend/routes/recipeLibrary.js`, new `backend/lib/redact.js` |

## Problem

1. **Raw phone numbers in logs.** `POST /auth/request-code` logs
   `phone=<E.164> ip=<ip> ua=<ua>` on every hit (`routes/auth.js` ~line 123).
   Render keeps these logs on its own retention schedule, and the privacy
   policy doesn't mention it.
2. **Phone number used as a display-name fallback** in text sent to other
   people. The project already removed phone numbers from API responses for
   exactly this reason (see `publicUser` in `routes/friends.js`), but these
   remain:
   - `routes/friends.js:277`, `:287` (push and SMS for a friend request),
     `:345` (accepted push)
   - `routes/groups.js:537`, `:546` (group invite push and SMS)
   - `routes/invites.js:201` (joined push)
   - `routes/recipeLibrary.js:595` (sharer name)

## Goal

No raw phone number appears in logs or in any message sent to another user.

## Acceptance criteria

- [ ] `lib/redact.js` exports `redactPhone(e164)` that returns `"+1•••••1234"`
      (country code and last 4 digits), and `phoneLogKey(e164)` that returns
      a 12-hex-character HMAC-SHA256 of the number using `LOG_HASH_SECRET`
      (falling back to `JWT_SECRET` if unset, so it always works). The HMAC
      lets you correlate repeated hits on one number in logs without storing
      the number.
- [ ] The request-code log line uses `phone=${redactPhone(n)} phoneKey=${phoneLogKey(n)}`.
      IP and User-Agent stay.
- [ ] `grep -rn "phoneNumber ||" backend/routes backend/index.js` (and the
      `?.phoneNumber ||` form) returns nothing. Every fallback becomes
      `displayName || "Someone"` (or "A friend" where that reads better).
- [ ] No other `console.log` or `console.error` line prints a raw phone
      number. Grep for `phone` in log statements and check each one.
      `console.error(..., error)` calls that pass Twilio errors may echo the
      `to` number inside the error object. Log `error.code` and
      `error.message` instead of the whole object for Twilio calls.
- [ ] Unit tests for `redactPhone` and `phoneLogKey`.
- [ ] `LOG_HASH_SECRET` is added to `.env.example`.

## Steps

1. Create `lib/redact.js` with the two functions (`crypto.createHmac`).
2. Update the log line in `routes/auth.js`. Update its long comment so it no
   longer says the phone number is logged in the clear.
3. Replace each fallback listed above.
4. In `lib/twilio.js` (`sendInviteSMS`) and `routes/auth.js` (Verify
   send/check catches), change `console.error("...", error)` to
   `console.error("...", error?.code, error?.message)`.
5. Unit tests in `test/unit/redact.test.js`.

## Follow-up for A3

The privacy policy should say that sign-in attempts are logged with IP
address, User-Agent, and a redacted phone number for abuse prevention, and
for how long. A3 owns the policy text.
