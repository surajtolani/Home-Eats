# A9 — SwiftData versioned schema baseline

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | Data loss for real users on any future update |
| Depends on | — |
| Size | M |
| Touches | `HomeEats/App/HomeEatsApp.swift`, new `HomeEats/Models/Schema/HomeEatsSchemaV1.swift`, new `HomeEats/Models/Schema/HomeEatsMigrationPlan.swift` |

## Problem

`HomeEatsApp.swift` (~lines 83–125) builds the `ModelContainer` from a bare
schema. When a schema change can't be migrated automatically, it moves the
store aside and **starts with an empty database**. That's fine for TestFlight
but not for App Store users: local-only data (personal meal plans, grocery
lists, staples, aisles, product photos) has no server copy and would vanish.
The README already says "shipping a schema change like this for real would
need an actual SchemaMigrationPlan".

SwiftData can only migrate between versions it knows about, so the v1 schema
must be captured **in the 1.0 build** to give 1.1 a defined starting point.

## Goal

1.0 ships with `HomeEatsSchemaV1: VersionedSchema` and a
`SchemaMigrationPlan` containing that single version. The store-quarantine
fallback stays as a last resort, and its user-visible effect is announced
instead of silent.

## Acceptance criteria

- [ ] `enum HomeEatsSchemaV1: VersionedSchema` with
      `versionIdentifier = Schema.Version(1, 0, 0)` and `models` listing
      **exactly** the model types currently passed to `Schema(...)` in
      `HomeEatsApp.swift`, in no particular order.
- [ ] `enum HomeEatsMigrationPlan: SchemaMigrationPlan` with
      `schemas = [HomeEatsSchemaV1.self]` and `stages = []`.
- [ ] The `ModelContainer` is created with
      `ModelContainer(for: Schema(versionedSchema: HomeEatsSchemaV1.self), migrationPlan: HomeEatsMigrationPlan.self, configurations: [configuration])`.
- [ ] **No model's stored properties change in this PR.** The v1 schema must
      be identical to what TestFlight users have now, so their existing
      stores open without hitting the fallback.
- [ ] If the quarantine fallback ever runs, set a `UserDefaults` flag. On
      next appearance, the root view shows a one-time alert: "We couldn't
      upgrade data stored on this iPhone. Anything synced to your account
      will reappear shortly." Personal synced data comes back through
      `PersonalLibrarySyncService`.
- [ ] A comment block in `HomeEatsMigrationPlan.swift` explains how to add V2:
      copy the model types into a `HomeEatsSchemaV2` namespace, add a
      `MigrationStage.lightweight` or `.custom`, and never edit V1's models
      after release.
- [ ] `iOS Build` action is green.

## Steps

1. Read `HomeEatsApp.swift` and list every type in its `Schema([...])`.
2. Create the two files in a new `HomeEats/Models/Schema/` folder.
   `project.yml` includes `HomeEats/` recursively, so no project change is
   needed.
3. The model classes are top-level `@Model final class`es today. For V1,
   reference them directly (`FamilyMember.self`, ...). You don't need to
   nest them inside the enum for the first version. Note in the comment that
   V2 will need nested copies.
4. Swap the container construction. Keep the existing `do/catch` and
   `moveStoreAside` fallback around it, and add the `UserDefaults` flag in
   the catch branch.
5. Add the one-time alert in `RootView.swift`.
6. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- Before release, install the current TestFlight build on a device and
  create data. Then install this build over it and confirm the data is
  still there (the fallback alert must **not** appear).

## Out of scope

- Any actual schema change.
- Moving personal local-only data to the server.
