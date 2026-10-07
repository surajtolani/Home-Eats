# A4 — Data minimization at sign-up

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | Rejection risk (Guideline 5.1.1(i)–(iii): only require data relevant to core functionality) |
| Depends on | — |
| Size | S |
| Touches | `backend/routes/me.js`, `HomeEats/Views/Root/RootView.swift`, `HomeEats/Views/Account/ProfileCompletionStepView.swift`, `HomeEats/Views/Account/EditProfileView.swift`, `HomeEats/Services/AccountModels.swift` (if it mirrors `profileComplete`) |

## Problem

After SMS verification, the app blocks all use until the user enters first
name, last name, city, state, **and** country (`computeProfileComplete`,
`routes/me.js:27`; gated in `RootView.swift`). City, state, and country
aren't needed for meal planning. A reviewer can flag requiring them as
collecting personal data that isn't needed. Combined with mandatory sign-in
for features that work locally, this makes a 5.1.1 rejection likely.

## Goal

The only required profile field is a **display name**, because other group
members need to see who did what. Everything else is optional and editable
later.

## Acceptance criteria

- [ ] `computeProfileComplete(user)` returns `Boolean(user.displayName?.trim())`.
- [ ] The onboarding step asks for one field, "What should your family and
      friends call you?", saved as `displayName`. First name, last name, and
      location are optional in Edit Profile, not in onboarding.
- [ ] Existing users who completed the old five-field profile but have no
      `displayName`: backfill. On read, if `displayName` is empty and
      `firstName` is set, `GET /me` returns `profileComplete: true` and the
      server sets `displayName = firstName + " " + lastName`. Alternatively,
      do a one-time SQL backfill in a migration (recommended:
      `UPDATE "User" SET "displayName" = trim(coalesce("firstName",'') || ' ' || coalesce("lastName",'')) WHERE ("displayName" IS NULL OR "displayName" = '') AND "firstName" IS NOT NULL;`).
- [ ] Location fields stay available in Edit Profile, labeled "Optional,
      used to suggest nearby restaurants". If nothing actually uses the
      profile city for suggestions, remove the fields from the UI entirely
      and say so in the PR. Grep `city` usage in `HomeEats/` before deciding.
- [ ] Integration test: a user with only `displayName` → `profileComplete: true`.

## Steps

1. Backend: change `computeProfileComplete`, add the backfill migration, and
   update the comments in `routes/me.js` that describe five required fields.
2. iOS: find the completion gate in `RootView.swift` (search for
   `profileComplete`) and the onboarding form (`ProfileCompletionStepView.swift`).
   Reduce it to a single display-name field that calls
   `AccountsAPIClient.updateProfile(displayName:)` (check the method's
   signature around `AccountsAPIClient.swift:277`).
3. iOS: make the other fields in `EditProfileView.swift` clearly optional.
   They must not block saving when empty. The backend `PATCH /me` already
   accepts partial updates, but its schema rejects empty strings, so send
   only changed non-empty fields.
4. Update the privacy policy line about profile data if A3 has already
   landed.
5. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- In App Review notes, write one sentence explaining why an account is
  needed: "Home Eats is a shared household planner; an account (phone
  number) lets family members see the same meal plan and grocery list."

## Out of scope

- Letting people use the app without an account (R6). Do it if time allows
  before 1.0, because it removes this rejection risk entirely.
