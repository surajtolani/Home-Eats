# A2 — App Review sign-in access

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | **Rejection** (Guideline 2.1: reviewers must be able to access the app) |
| Depends on | S1 (durable limits) |
| Size | S |
| Touches | `backend/routes/auth.js`, `backend/.env.example`, `backend/README.md` |

## Problem

The only way in is phone number + SMS code (Twilio Verify), and sign-in can't
be skipped (`RootView.swift:111`). App Review needs working credentials
included with the submission, and reviewers can't receive SMS sent to your
phone. Without a review path, the submission gets rejected as "unable to sign
in".

## Goal

A narrowly scoped, environment-gated review login: one specific phone number
accepts one specific static code without calling Twilio, and is disabled
when the environment variables aren't set.

## Acceptance criteria

- [ ] New environment variables `REVIEW_LOGIN_PHONE` (E.164) and
      `REVIEW_LOGIN_CODE` (must be **≥ 8 digits**; the server refuses to
      enable the feature and logs an error if it's shorter).
- [ ] Both variables unset → behavior is identical to today.
- [ ] `POST /auth/request-code` with `REVIEW_LOGIN_PHONE`: skips Twilio, runs
      the same rate limiters, returns `{ ok: true }`.
- [ ] `POST /auth/verify-code` with `REVIEW_LOGIN_PHONE`: compares the code
      with `crypto.timingSafeEqual` (equal-length buffers; mismatched lengths
      count as a failure), skips Twilio, then continues through the normal
      find-or-create user path.
- [ ] The verify-code limiters still apply, and that phone number's limit is
      tightened to **5 per hour**.
- [ ] Every review login is logged:
      `[review-login] success|failure ip=<ip> ua=<ua>`.
- [ ] The review account is a normal user and gets no extra privileges.
- [ ] Tests: correct code → token; wrong code → 400; variables unset → the
      number goes through the Twilio path (stub).

## Steps

1. In `routes/auth.js` add:
   ```js
   // App Review can't receive our SMS codes, so one designated number can
   // sign in with a static code. Disabled unless both env vars are set.
   function reviewLoginConfig() { ... }  // returns { phone, code } or null
   ```
   Validate the length here. Read `process.env` on each call so tests can
   toggle it.
2. Branch at the top of both handlers, **after** body validation and rate
   limiting, **before** the Twilio client check.
3. Add a separate limiter `verify-code:review` (1 h, 5) keyed on the phone
   number, checked only on this path.
4. `.env.example` and README: document both variables, say to use a real
   number you control (not one anyone else could own), and to rotate the code
   after each review cycle.
5. Seed the review account so the reviewer sees real features. Create a
   script `backend/scripts/seed-review-account.js` that, for
   `REVIEW_LOGIN_PHONE`, creates or updates the user with a name, a sample
   group "Review Household" with a second seeded member, three recipes, a
   meal plan for the current week, and a grocery list. The script must be
   idempotent: running it again resets that content.

## [HUMAN] steps

- Set `REVIEW_LOGIN_PHONE` and `REVIEW_LOGIN_CODE` in Render, then run the
  seed script once (Render Shell: `node scripts/seed-review-account.js`).
- In App Store Connect → App Review Information → Sign-in required: enter the
  phone number as the user name and the code as the password. In the notes,
  write: "Enter this phone number on the sign-in screen; when asked for the
  SMS code, enter the password above. No SMS will be sent."
- After approval, consider rotating `REVIEW_LOGIN_CODE`. Keep the variables
  set, though, because Apple re-reviews on every update.
