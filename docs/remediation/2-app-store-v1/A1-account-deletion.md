# A1 — In-app account deletion

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | **Rejection** (App Store Review Guideline 5.1.1(v)) |
| Depends on | S5 (sign-out plumbing) |
| Size | L |
| Touches | `backend/routes/me.js`, `backend/prisma/schema.prisma` + migration, `backend/routes/*` serializers, `HomeEats/Services/AccountsAPIClient.swift`, `HomeEats/Services/AccountSession.swift`, `HomeEats/Services/AccountModels.swift`, `HomeEats/Views/Settings/SettingsView.swift` |

## Problem

Apps that let users create an account must let them start deleting it
**from inside the app**. Deactivation alone doesn't count. There's no
delete endpoint (`routes/me.js:58`: "there's no delete-account flow yet") and
no option in the app. The privacy policy (`index.js` ~line 289) already
claims in-app deletion exists.

## Goal

`DELETE /me` permanently removes the user and their personal data, keeps
shared group data usable for the remaining members, and the app exposes it
in Settings.

## Decisions (already made, don't re-litigate)

- **Hard delete**, not soft delete. No grace period for 1.0.
- **Group content the user contributed is kept and de-attributed**, not
  deleted. Planned meals they decided, suggestions they made, and grocery
  items they added stay for the group and show "Former member". This needs a
  schema change from `Cascade` to `SetNull` on three relations (step 1).
  Fallback if time-boxed: keep `Cascade` (their contributions disappear) and
  say so in the PR. This is acceptable for review but worse for users.
- **Last manager handling:** if the user is the only MANAGER of a group with
  other members, promote the longest-standing remaining member (earliest
  `GroupMembership.joinedAt`) to
  MANAGER. If they're the only member, delete the group.
- **Recipes they own are deleted**, including ones published to the public
  library (cascades to shares, reports, and ingredients). Meal history
  entries and plans that referenced them already `SetNull`.

## Acceptance criteria

- [ ] Migration: `PlannedMeal.decidedByUserId`,
      `MealSuggestion.proposedByUserId`, and `GroupGroceryItem.addedByUserId`
      become nullable with `onDelete: SetNull`.
- [ ] All serializers that read those relations handle `null` (API emits
      `null` for the user fields), and iOS decoders accept `null` and display
      "Former member".
- [ ] `DELETE /me` (requires auth), body
      `{ confirm: "DELETE" }`, in one transaction:
      1. Handle last-manager promotion or group deletion per group.
      2. Delete `Invite` rows where `invitedPhoneNumber = user.phoneNumber`.
         Invites they *sent* cascade already.
      3. Delete the `User` row. Everything else cascades or gets set to
         null.
      4. Returns 204.
- [ ] Any token for the deleted user → 401 afterwards. This already holds
      because `requireAuth` looks the user up.
- [ ] Re-signing up with the same phone number creates a fresh, empty
      account.
- [ ] Integration tests: sole member → group deleted; sole manager with
      participants → a participant gets promoted; the deleted user's
      suggestion stays with `proposedByUser: null`; public recipe is gone
      from `/recipe-library/master`; old token → 401.
- [ ] iOS: Settings → "Delete Account" (destructive, at the bottom of the
      account section). It opens a confirmation sheet that explains what gets
      deleted and what stays in groups, and requires typing `DELETE`. On
      success, purge local group data (the same path sign-out uses) and clear
      the local session. Offer a toggle (default on) "Also erase recipes and
      plans stored on this iPhone", which deletes local SwiftData personal
      data.
- [ ] Privacy policy "Data Retention and Deletion" section accurately
      describes this. Coordinate with A3. If A3 hasn't landed, edit just that
      section here.

## Steps

### Backend

1. **Schema.** In `schema.prisma`, change the three relations to optional
   (`User?`, `String?`) with `onDelete: SetNull`. Write a migration with
   `ALTER COLUMN ... DROP NOT NULL` and recreate the foreign keys with
   `ON DELETE SET NULL`. Match the naming in existing migrations, e.g.
   `20260913010000_group_created_by_nullable_setnull`, which did exactly this
   for `Group.createdByUserId`. Copy its pattern.
2. **Serializers.** Grep for `decidedByUser`, `proposedByUser`, and
   `addedByUser` in `backend/routes/`. Every `x.decidedByUser.displayName`
   becomes `x.decidedByUser?.displayName ?? null`. Make sure the meal plan
   vote summary and grocery list code don't throw on `null`.
3. **Endpoint** in `routes/me.js`:
   - Validate `{ confirm: z.literal("DELETE") }`.
   - Load the user's memberships with group member counts and manager
     counts. For each group:
     - Only member → `group.delete`.
     - The user is a MANAGER, manager count is 1, and other members exist →
       promote the earliest-joined other member. Reuse the counting logic
       from `wouldStrandGroup` (`routes/groups.js` ~line 101). Consider
       moving it into a shared helper rather than copying it.
   - `invite.deleteMany({ where: { invitedPhoneNumber: user.phoneNumber } })`.
   - `user.delete({ where: { id } })`.
   - Wrap everything in `prisma.$transaction(async (tx) => ...)`.
   - Log `[account-deleted] userId=<id> at=<iso>` (no phone number; see S6).
4. Document `DELETE /me` in `backend/README.md`. Remove the "no
   delete-account flow yet" comment in `routes/me.js`.

### iOS

5. **Decoders.** In `HomeEats/Services/AccountModels.swift`, find the types
   that decode `decidedByUser`, `proposedByUser`, and `addedByUser` (or
   flattened name fields). Make them optional. Update the views that show
   them to fall back to `"Former member"`. Grep the `Views/` folder for each
   property name. Update `HomeEatsTests/GroupSharedPlanDecodingTests.swift`
   with a `null` case.
6. **API.** Add `static func deleteAccount() async throws` to
   `AccountsAPIClient`: `DELETE /me` with body `{"confirm":"DELETE"}`. Check
   whether `sendNoContent` supports a body for `DELETE`, and extend it if
   not.
7. **UI.** New `HomeEats/Views/Account/DeleteAccountView.swift` (sheet):
   explanation text, the "Also erase data on this iPhone" toggle, a
   `TextField` that must equal `DELETE`, and a destructive button that's
   disabled until it matches. Show a progress state while the call runs.
   On error, show an alert and stay signed in. On success:
   1. `GroupSyncService.purgeAllLocalGroupData(modelContext:)`
      (`GroupSyncService.swift:1027`);
   2. if the toggle is on, delete all personal SwiftData models. Write a
      small `LocalDataEraser.eraseAll(modelContext:)` in `Services/` that
      deletes every model type listed in `HomeEatsApp`'s schema, then
      re-seeds via `SampleDataSeeder` so the app is in first-launch state;
   3. `accountSession.clearLocalSession()` (from S5).
8. Add the entry point in `SettingsView.swift`.
9. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- In App Store Connect review notes, write: "Account deletion: Settings →
  Delete Account."
- Make sure database backups on Render honor deletion within your stated
  retention window, and state that window in the privacy policy (A3).
