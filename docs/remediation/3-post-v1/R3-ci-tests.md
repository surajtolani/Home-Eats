# R3 — Run backend and iOS tests in CI

| | |
|---|---|
| Phase | 3 — Post-1.0 (pull earlier if regressions start appearing) |
| Severity | Quality |
| Depends on | S0 |
| Size | M |
| Touches | new `.github/workflows/backend.yml`, `.github/workflows/ios-build.yml` |

## Problem

- There's no backend CI at all, so the access-control and abuse-limit logic
  added in Phase 1 can regress silently.
- iOS CI only compiles. Its header comment says `xcodebuild test` failed with
  "Could not find test host for HomeEatsTests", so unit tests never run.

## Acceptance criteria

- [ ] `.github/workflows/backend.yml` runs on PRs and pushes that touch
      `backend/**`: Node 20, a Postgres 16 service container, `npm ci`,
      `npx prisma migrate deploy`, then `npm test` with `TEST_DATABASE_URL`
      set. Integration tests **run** there; they must not be skipped.
- [ ] A CI check that every Prisma schema change has a migration:
      `npx prisma migrate diff --from-migrations prisma/migrations --to-schema-datamodel prisma/schema.prisma --shadow-database-url $TEST_DATABASE_URL --exit-code`.
- [ ] iOS: unit tests run in CI. Likely causes of the test-host error to try,
      in order:
      1. In `project.yml`, the `HomeEatsTests` target needs
         `settings.base.TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Home Eats.app/Home Eats"`
         and `BUNDLE_LOADER: "$(TEST_HOST)"`. The product name has a space
         ("Home Eats"), so XcodeGen's default may be wrong.
      2. Use `xcodebuild test -scheme HomeEats -destination 'platform=iOS Simulator,name=<an available device>'`,
         and pick the device dynamically from `xcrun simctl list devices available`.

      If it still fails after reasonable attempts, record what was tried in
      the PR and leave compile-only CI in place.
- [ ] `npm audit --omit=dev --audit-level=high` runs as a non-blocking job,
      and Dependabot is configured for `backend/` npm and GitHub Actions.

## Out of scope

- UI tests.
