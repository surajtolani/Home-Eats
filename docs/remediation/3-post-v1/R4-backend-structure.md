# R4 — Split `index.js`, deduplicate shared helpers

| | |
|---|---|
| Phase | 3 — Post-1.0 |
| Severity | Maintainability |
| Depends on | R3 (tests in CI catch regressions from the move) |
| Size | M |
| Touches | `backend/index.js` / `app.js`, new `backend/routes/proxy/*.js`, new `backend/lib/membership.js`, new `backend/public/*.html` |

## Problem

- `backend/index.js` (1,335 lines) mixes app setup, Google Places, Geocoding,
  Custom Search, Anthropic proxy routes, the image proxy, an inline HTML
  privacy policy, terms, and the SMS consent page, plus server startup.
- `membershipFor`, `requireMembership`, `publicUser`, and `isAcceptedFriend`
  are copied across `groups.js`, `groupMealPlan.js`, `groupGrocery.js`, and
  `groupGroceryAisles.js` (each file's comments say so). A fix to one copy
  won't reach the others.
- Comments narrate change history at length ("direct user report", "a real,
  confirmed finding"), which buries the actual logic.

## Acceptance criteria

- [ ] `app.js` only wires middleware and mounts routers, in under 150 lines.
- [ ] `routes/proxy/places.js`, `routes/proxy/ai.js`,
      `routes/proxy/webSearch.js`, and `routes/proxy/imageProxy.js` hold the
      former inline routes, each with its own limiters.
- [ ] `lib/membership.js` holds `membershipFor`, `requireMembership`,
      `isManager`, and `wouldStrandGroup`. `lib/users.js` holds `publicUser`
      and `isAcceptedFriend`. All copies are deleted, and the routes import
      the shared versions.
- [ ] Policy pages become static files in `backend/public/` (`privacy.html`,
      `terms.html`, `sms-consent.html`), served at the same paths
      (`/privacy`, `/terms`, `/sms-consent`) with
      `res.sendFile`. If `smsConsentHtml()` builds dynamic content (it
      references screenshots), keep it as a small render function in
      `routes/pages.js`.
- [ ] **Pure move:** no behavior change. Tests pass before and after, and the
      PR description lists every moved symbol.
- [ ] Comments trimmed to explain *why* in a few sentences. Incident history
      goes to `git log` and PR descriptions, not code comments.
