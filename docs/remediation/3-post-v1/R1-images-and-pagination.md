# R1 — Move photos to object storage, paginate recipe lists

| | |
|---|---|
| Phase | 3 — Post-1.0 |
| Severity | Scale and performance (becomes a cost and abuse issue as users grow) |
| Depends on | S4 (authenticated image loading on iOS) |
| Size | L |
| Touches | `backend/prisma/schema.prisma`, `backend/routes/recipeLibrary.js`, new `backend/lib/storage.js`, iOS recipe sync and library views |

## Problem

- Recipe photos are stored as base64 text in Postgres (`Recipe.photoBase64`,
  up to 5 MB decoded each) and embedded in every list response
  (`serializeRecipe`, `recipeLibrary.js:58`).
- `GET /recipe-library/master` returns **every** public recipe from every
  user, with no pagination (`recipeLibrary.js:346`). `/mine` and
  `/shared-with-me` are also unbounded.
- One user publishing 50 photo recipes adds about 300 MB to *everyone's*
  library download. The database bloats, and backups and restores slow down.

## Goal

Photos live in S3-compatible object storage. List endpoints return
thumbnail and full-size URLs, not bytes, and paginate with a cursor.

## Acceptance criteria

- [ ] `lib/storage.js` wraps an S3-compatible client (AWS S3, Cloudflare R2,
      or Backblaze B2; chosen by a human) with
      `putObject(key, buffer, contentType)`, `deleteObject(key)`, and
      `signedGetURL(key, ttlSeconds)`. It's configured by `S3_ENDPOINT`,
      `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, and `S3_REGION`.
- [ ] On recipe create or update with a photo, the server decodes the image,
      verifies it's JPEG, PNG, or WebP by magic bytes, re-encodes it to strip
      EXIF (and GPS), stores a full-size (≤ 1600 px) and a thumbnail
      (≤ 400 px) version, and saves `photoKey` on the recipe. Use `sharp`
      (new dependency).
- [ ] The API returns `photoURL` and `thumbnailURL` as short-lived signed
      URLs (1 h), with no Authorization header needed. iOS can use plain
      `AsyncImage` or `RemoteImage` for these.
- [ ] `photoBase64` is still **accepted** on write for one release, so older
      app builds keep working. It's **no longer returned** once the iOS
      version that reads `photoURL` is the minimum supported version.
      Document the two-step rollout in the PR.
- [ ] A backfill script `scripts/migrate-photos-to-storage.js` moves existing
      `photoBase64` data to storage in batches and is idempotent.
- [ ] `/master`, `/mine`, and `/shared-with-me` accept `?cursor=<id>&limit=<n≤50>`,
      ordered by `(createdAt desc, id desc)`, and return `{ recipes, nextCursor }`.
      iOS loads more on scroll.
- [ ] Deleting a recipe deletes its stored objects (best effort, logged on
      failure).

## Steps

Plan the steps in your PR description first, because this touches the API
contract. Follow the expand/contract order: add the new fields, ship the
iOS build that reads them, then stop sending the old ones.

## [HUMAN] steps

- Choose a provider, create the bucket (private), create scoped
  credentials, and set the environment variables on Render.
