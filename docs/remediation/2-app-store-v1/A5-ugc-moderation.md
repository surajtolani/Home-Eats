# A5 — User-generated content safeguards: block, hide, moderate

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | **Rejection** (Guideline 1.2, user-generated content) |
| Depends on | S0 |
| Size | L |
| Touches | `backend/prisma/schema.prisma` + migration, `backend/routes/recipeLibrary.js`, `backend/routes/friends.js`, `backend/routes/groups.js`, new `backend/routes/blocks.js`, new `backend/scripts/moderation.js`, iOS views for library, recipe detail, friends |

## Problem

The public recipe library (`GET /recipe-library/master`) shows every user's
published recipes to every other user. Guideline 1.2 requires **all** of:

| Requirement | Today |
|---|---|
| Filtering objectionable content before it's posted | None |
| A way to report offensive content | Present (`POST /:recipeId/report`, `ReportRecipeButton.swift`) |
| The ability to block abusive users | **Missing** |
| Contact info and acting on reports within 24 h | Reports only sit in a table (`recipeLibrary.js:710`). No takedown mechanism, no alerting. |
| Terms that forbid objectionable content | Missing (A3 adds the clause) |

Publishing can't be undone, so an owner can't remove their own public
recipe from the library.

## Goal

Meet every 1.2 requirement with the smallest reasonable system: a word
filter at publish time, user blocking, automatic hiding when a recipe gets
enough reports, an owner unpublish action, an operator script for takedowns
and bans, and an alert when reports arrive.

## Acceptance criteria

### Data model
- [ ] `UserBlock { blockerId, blockedId, createdAt, @@id([blockerId, blockedId]) }`,
      both foreign keys `onDelete: Cascade`.
- [ ] `Recipe.moderationStatus` enum `VISIBLE | HIDDEN`, default `VISIBLE`.
- [ ] `User.bannedAt DateTime?`.

### Behavior
- [ ] **Filter:** `POST /:recipeId/publish` runs title, summary, ingredient
      names, and instructions through `lib/contentFilter.js` (a small word
      list with whole-word, case-insensitive matching plus a URL check that
      rejects `http(s)://` and bare domains). On a match → 422 "This recipe
      can't be published because it contains language that isn't allowed."
      The word list lives in `backend/lib/contentFilterWords.json`. Seed it
      with a standard English profanity and slur list, and note in the PR
      which source list was used.
- [ ] **Block:** `POST /blocks { userId }`, `DELETE /blocks/:userId`,
      `GET /blocks`. Blocking also:
      - hides the blocked user's recipes from the blocker's `/master`,
        `/shared-with-me`, and `GET /:recipeId` (403);
      - auto-declines any pending friendship between them and prevents new
        friend requests either way (the requester gets a generic "Couldn't
        send request.", with no hint about the block);
      - prevents either user from inviting the other to a group.
      Existing shared group membership is **not** changed (that's the group
      manager's call), and a short note says so in the README.
- [ ] **Auto-hide:** when a recipe reaches **3 distinct reporters**, set
      `moderationStatus = HIDDEN`. Hidden recipes are excluded from `/master`
      for everyone, and stay visible to their owner with a "Hidden pending
      review" flag in the response (`moderationStatus` is serialized).
- [ ] **Reporter-side hide:** once a user reports a recipe, it's excluded
      from *their* `/master` immediately.
- [ ] **Unpublish:** `POST /:recipeId/unpublish` (owner only) sets
      visibility back to `SHARED` if it has shares, or `PRIVATE` otherwise.
      Update the "one-way" comments on publish.
- [ ] **Banned users:** `requireAuth` rejects users with `bannedAt` set
      (403 `{ error: "This account has been suspended." }`). Their public
      recipes are excluded from `/master`.
- [ ] **Alerting:** every new report triggers a fire-and-forget POST to
      `MODERATION_WEBHOOK_URL` (if set) with `{ recipeId, reason, reportCount }`.
      Slack and Discord incoming webhooks both accept a `{ text }` body, so
      send `{ text: "..." }`.
- [ ] **Operator script** `backend/scripts/moderation.js` with these
      commands:
      - `list-reports [--since 7d]`
      - `hide <recipeId>`
      - `unhide <recipeId>`
      - `ban <userId>`: sets `bannedAt`, bumps `tokenVersion`, deletes
        device tokens, and hides all of the user's PUBLIC recipes
      - `unban <userId>`

      Run with `node scripts/moderation.js <cmd>` in Render Shell.
- [ ] **iOS:**
      - "Block <name>" on the recipe detail screen for others' recipes (next
        to Report) and on friend rows. Confirmation dialog first; on success,
        dismiss the screen and refresh the library.
      - "Blocked Users" list in Settings with Unblock.
      - "Remove from Library" (unpublish) on your own published recipes.
      - "Hidden pending review" badge on your own hidden recipes.
      - The publish flow shows the 422 message.
- [ ] Integration tests for the filter, block effects (library, friend
      request, group invite), the auto-hide threshold, unpublish, and the
      banned → 403 behavior.

## Steps

1. Schema and migration.
2. `lib/contentFilter.js`, with unit tests (including "Scunthorpe"-style
   false positives: whole-word matching only).
3. `routes/blocks.js`, mounted at `/blocks` with `requireAuth` in `index.js`.
   Add a helper `isBlockedEitherWay(tx, a, b)` in a shared lib file, and call
   it in `friends.js` `POST /request` and `groups.js`
   `POST /:groupId/invite` (both the userId and phoneNumber branches. For
   phoneNumber, look up the user first).
4. `recipeLibrary.js`:
   - `/master` adds `moderationStatus: "VISIBLE"`, excludes owners who are
     banned or blocked in either direction, and excludes recipes the caller
     reported.
   - `/shared-with-me` excludes blocked sharers.
   - `loadRecipeForViewer` returns `allowed: false` when blocked either way
     and the caller isn't the owner.
   - The report route counts distinct reporters after the upsert and hides at
     3, then fires the webhook.
   - Add the unpublish route.
5. `requireAuth`: add `bannedAt` to the `select` and check it.
6. The operator script.
7. iOS:
   - `AccountsAPIClient` methods `blockUser`, `unblockUser`, `getBlocks`,
     and `unpublishRecipe`.
   - The UI listed above. Look at `Views/Shared/ReportRecipeButton.swift` for
     the existing report pattern and put the Block action beside it.
   - Decode the new `moderationStatus` as an optional field so older payloads
     still decode.
   - Push and confirm the `iOS Build` action is green.
8. README: a "Moderation" section with the operator commands and the 24 h
   response expectation.

## [HUMAN] steps

- Create a Slack or Discord channel webhook and set `MODERATION_WEBHOOK_URL`
  on Render.
- Someone has to commit to checking reports daily. Apple expects action
  within 24 h.
- In App Review notes, describe the filter, report, block, and moderation
  flow in two sentences.
