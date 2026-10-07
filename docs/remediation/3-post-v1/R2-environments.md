# R2 — Staging and production environments

| | |
|---|---|
| Phase | 3 — Post-1.0 |
| Severity | Ops (every test build today writes to the production database) |
| Depends on | — |
| Size | M |
| Touches | `project.yml`, new `Config/*.xcconfig`, `HomeEats/Supporting/Info.plist`, the 5 Swift files that hardcode the base URL, new `HomeEats/Services/BackendConfig.swift` |

## Problem

`https://home-eats-uqbp.onrender.com` is hardcoded separately in
`AccountsAPIClient.swift:56`, `ClaudeRecipeService.swift:65`,
`GooglePlacesService.swift:11`, `RecipeWebSearchService.swift:56`, and
`RecipeImageProxy.swift:12`. Debug, TestFlight, and App Store builds all hit
production. There's no staging backend to test migrations or risky changes
against.

## Acceptance criteria

- [ ] `HomeEats/Services/BackendConfig.swift` exposes
      `static let baseURL: URL`, read from the Info.plist key
      `HomeEatsBackendURL`. A missing or invalid value triggers
      `assertionFailure` in Debug and falls back to production in Release.
- [ ] All 5 files use `BackendConfig.baseURL`. No other hardcoded backend
      URL remains (`grep -rn onrender.com HomeEats` returns nothing).
- [ ] `Config/Debug.xcconfig` and `Config/Release.xcconfig` set
      `HOMEEATS_BACKEND_URL`. Info.plist sets
      `HomeEatsBackendURL = $(HOMEEATS_BACKEND_URL)`. Wire it up in
      `project.yml` (`configFiles:` per configuration, plus an `info.properties`
      entry). In xcconfig, `//` starts a comment, so write
      `https:/$()/host` for URLs.
- [ ] Optional third configuration `Staging` (Release-like, staging URL)
      with a scheme that archives with it, used for TestFlight-internal
      builds.
- [ ] A `backend/README.md` section on running a staging Render service plus
      database from the same repo branch.

## [HUMAN] steps

- Create the staging Render service and Postgres, with separate Twilio
  Verify service, APNs sandbox, and API keys with low quotas.
