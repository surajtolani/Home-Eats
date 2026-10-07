# R6 — Guest mode (use the app without an account)

| | |
|---|---|
| Phase | 3 — Post-1.0 (pull into 1.0 if App Review rejects under 5.1.1(v) despite A4) |
| Severity | Product; removes the "account required" rejection risk entirely |
| Depends on | A4 |
| Size | L |
| Touches | `HomeEats/Views/Root/RootView.swift`, `HomeEats/Services/AccountSession.swift`, `HomeEats/Services/ActiveGroupSession.swift`, Plan and Grocery tab roots, Settings |

## Problem

`RootView.swift:111` presents `AccountSignInView(allowsCancel: false)`, so
nothing works without signing in. Most of the app (personal recipes,
`CalendarPlanView`/`DayDetailView` planning, `GroceryListView`, staples,
aisles, history) is built on local SwiftData models and was designed to work
offline with no account (see the original README). Apple's guideline
5.1.1(v): "If your app doesn't include significant account-based features,
let people use it without a login."

## Goal

First launch offers "Sign in with phone" or "Continue without an account".
Guests get the personal, local feature set. Group, friends, sharing, public
library, and AI and search proxy features show a sign-in prompt.

## Acceptance criteria

- [ ] An `AccountSession.isGuest` flag persisted in `UserDefaults`, set by
      "Continue without an account".
- [ ] `RootView`: when `!isSignedIn && isGuest`, show the main tab UI. The
      Plan and Grocery tabs show the **personal** views (`CalendarPlanView`,
      `GroceryListView`) instead of the group-shared ones. Find where the
      tabs choose between personal and group content (likely keyed on
      `ActiveGroupSession`) and treat "guest" like "no active group".
- [ ] Every account-only entry point (Groups, Friends, Share, Publish,
      Library tab's public section, AI import, restaurant search via
      backend) shows a `SignInPromptView` sheet instead of failing. All of
      these call `AccountsAPIClient` or the backend services, so gate at the
      view entry points rather than inside the client.
- [ ] Restaurant search falls back to `MKLocalSearch` for guests. The README
      says this fallback already exists for when the backend isn't
      configured; reuse it.
- [ ] Signing in later keeps all local data, and `PersonalLibrarySyncService`
      uploads it as it does today.
- [ ] Settings shows "Sign In" for guests in place of the account section.
- [ ] `iOS Build` action is green. Manually walk through the guest flow on a
      device and list it in the PR.
