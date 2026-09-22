// Recipe sharing (Phase 2a) — recipes moving from purely on-device storage
// to something that can be shared between people, on top of the friends/
// groups layer built in Phase 1. Mounted at `/recipe-library` in index.js
// (deliberately NOT under `/recipes/*`, even though nothing here collides
// method+path with the existing `/recipes/extract`/`/recipes/recommend` —
// those are unrelated, unauthenticated, Claude-powered routes registered
// directly on `app` rather than as a router, and keeping this feature's
// auth-required CRUD+sharing API under its own distinct prefix avoids any
// risk of the two ever being confused with each other, in code or in the
// README). Every route here requires auth (mounted behind requireAuth in
// index.js), same as friends/groups.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");
const { sendPush } = require("../lib/apns");

const router = express.Router();

// Same "safe to hand back to someone with a legitimate relationship" shape
// as routes/friends.js's and routes/groups.js's own (duplicated, not
// imported) `publicUser` helpers — kept small and local rather than shared,
// matching how those two files already each keep their own copy. No
// `phoneNumber` — see routes/friends.js's own doc comment on its
// `publicUser` for why.
function publicUser(user) {
  return { id: user.id, displayName: user.displayName };
}

// Same accepted-friend check as routes/groups.js's `isAcceptedFriend` (also
// duplicated rather than imported, same reasoning as `publicUser` above) —
// used here so sharing a recipe directly with a userId has the same
// anti-stranger rule as adding someone to a group.
async function isAcceptedFriend(userIdA, userIdB) {
  const friendship = await prisma.friendship.findFirst({
    where: {
      status: "ACCEPTED",
      OR: [
        { requesterId: userIdA, recipientId: userIdB },
        { requesterId: userIdB, recipientId: userIdA },
      ],
    },
  });
  return Boolean(friendship);
}

function membershipFor(groupId, userId) {
  return prisma.groupMembership.findUnique({
    where: { userId_groupId: { userId, groupId } },
  });
}

// Shape returned for a Recipe (with its ingredients) everywhere below.
// Ingredients are always fetched `orderBy: { sortIndex: "asc" }` so callers
// never need to re-sort client-side.
function serializeRecipe(recipe) {
  return {
    id: recipe.id,
    ownerId: recipe.ownerId,
    title: recipe.title,
    summary: recipe.summary,
    instructions: recipe.instructions,
    servings: recipe.servings,
    prepMinutes: recipe.prepMinutes,
    cookMinutes: recipe.cookMinutes,
    visibility: recipe.visibility,
    // Base64 text, straight out of the `photoBase64` column — see that
    // column's own doc comment in prisma/schema.prisma for why it's stored
    // as text (so this needs no encode/decode step here) and for the size/
    // bloat tradeoff of sending it inline on every fetch of a recipe that
    // has one. `null` for the overwhelming majority of recipes (no
    // user-picked photo at all, or a `.library` recipe's bundled asset,
    // which never had bytes to send in the first place).
    photoBase64: recipe.photoBase64,
    // The recipe's origin page link, and a photo reference that's either a
    // bundled built-in asset name or a remote image URL — see the
    // `sourceUrl`/`imageName` columns' own doc comment in
    // prisma/schema.prisma for why both exist and what dropping them used
    // to silently lose.
    sourceUrl: recipe.sourceUrl,
    imageName: recipe.imageName,
    createdAt: recipe.createdAt,
    updatedAt: recipe.updatedAt,
    ingredients: (recipe.ingredients || []).map((ingredient) => ({
      id: ingredient.id,
      name: ingredient.name,
      quantity: ingredient.quantity,
      unit: ingredient.unit,
    })),
  };
}

const RECIPE_INGREDIENTS_INCLUDE = { ingredients: { orderBy: { sortIndex: "asc" } } };

const IngredientSchema = z.object({
  name: z.string().trim().min(1, "Every ingredient needs a name.").max(200),
  // Nullable: plenty of real ingredient lines have no numeric amount at all
  // (e.g. "salt to taste") — see the RecipeIngredient doc comment in
  // prisma/schema.prisma.
  quantity: z.number().finite().nullable().optional(),
  unit: z.string().trim().max(50).nullable().optional(),
});

// Shared per-field schemas so create/update can't drift apart. Built without
// any `.default()` — a `.default()` on a field fires even when that key is
// simply absent from the input (it doesn't mean "only when null"), which is
// exactly wrong for PATCH's "omitted field = leave unchanged" semantics
// (confirmed against zod's actual behavior, not just the docs: even wrapping
// a defaulted field in `.optional()`/`.partial()` still applies the default
// for a missing key, since `.partial()` only changes what's *required*, not
// whether a default underneath it still fires). Create supplies its own
// defaults explicitly in the route handler instead (`ingredients ?? []`
// isn't even needed since the field itself is always present in a create
// body's intent — see CreateRecipeSchema below).
// 200 each is a generous ceiling — a real recipe never has anywhere close
// to 200 ingredient lines or 200 instruction steps — while still bounding
// the request body size and the per-ingredient row count PATCH's
// delete-and-recreate (see the PATCH handler below) ever has to write in
// one transaction.
const MAX_INGREDIENTS = 200;
const MAX_INSTRUCTIONS = 200;

// A recipe photo, base64-encoded (see `Recipe.photoBase64`'s doc comment in
// prisma/schema.prisma for the full storage-shape/size-tradeoff reasoning).
// Checked against the DECODED byte length, not the base64 string's own
// length — base64 inflates size by ~33%, so capping the string length
// itself would actually cap the photo more tightly than this number
// suggests. 5MB decoded is real headroom above what the iOS upload path
// should ever actually send (`ImageResizing.downsized(...)` caps a photo at
// 800px on its long edge, JPEG-compressed, before it's ever base64-encoded
// for upload — see `RecipeSharePickerSheet`/`RecipeEditorView` — typically
// well under 500KB) while still bounding how much a single misbehaving or
// malicious request can bloat this table: a 5MB decoded photo is ~6.7MB of
// base64 JSON, comfortably inside the global 15mb `express.json` body limit
// (see index.js) with room for the rest of the request body around it.
const MAX_PHOTO_BYTES_DECODED = 5 * 1024 * 1024; // 5MB

// `Buffer.byteLength(str, "base64")` computes the decoded size directly
// from the encoded string's length (and its trailing `=` padding) without
// actually allocating/decoding a buffer — cheap enough to run on every
// create/update even for a multi-MB photo.
function decodedPhotoByteLength(base64) {
  return Buffer.byteLength(base64, "base64");
}

// Loose but real validation: base64 only ever uses these characters (plus
// up to two trailing `=` padding characters) — this catches an obviously
// malformed value (stray whitespace from a copy-paste, a data URI's
// `data:image/jpeg;base64,` prefix left on by mistake, ...) with a clear
// 400 rather than silently storing garbage text that will fail to decode
// as an image on every future viewer's device instead of failing loudly
// once, here, at write time.
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

const photoBase64Field = z
  .string()
  .min(1, "photoBase64 can't be an empty string — omit the field or send null instead.")
  .refine((value) => BASE64_PATTERN.test(value), {
    message: "photoBase64 must be valid base64 (no data URI prefix, no whitespace).",
  })
  .refine((value) => decodedPhotoByteLength(value) <= MAX_PHOTO_BYTES_DECODED, {
    message: `Recipe photo can't be more than ${Math.floor(MAX_PHOTO_BYTES_DECODED / (1024 * 1024))}MB.`,
  })
  .nullable();

const titleField = z.string().trim().min(1, "title can't be empty.").max(200);
const summaryField = z.string().trim().max(4000).nullable();
const ingredientsField = z
  .array(IngredientSchema)
  .max(MAX_INGREDIENTS, `A recipe can't have more than ${MAX_INGREDIENTS} ingredients.`);
const instructionsField = z
  .array(z.string().trim().min(1))
  .max(MAX_INSTRUCTIONS, `A recipe can't have more than ${MAX_INSTRUCTIONS} instruction steps.`);
const servingsField = z.number().int().positive().nullable();
const prepMinutesField = z.number().int().nonnegative().nullable();
const cookMinutesField = z.number().int().nonnegative().nullable();
// Generous ceiling for either a page URL or a long image URL — same
// "bound the request body, not the realistic use case" reasoning as every
// other max() here.
//
// `sourceUrlField` additionally requires an http(s) scheme — a real,
// confirmed finding: any signed-in user (a total stranger, once a recipe
// is published PUBLIC — see POST /:recipeId/publish below) could set this
// to a phishing page or an arbitrary URL scheme, and the client opens it
// directly as a tappable link with no validation of its own
// (RecipeDetailView.swift's "View Original Recipe"). Rejecting anything
// that isn't http/https here closes that off at the one place every
// recipe's sourceUrl is ever written.
const httpUrlPattern = /^https?:\/\//i;
const sourceUrlField = z
  .string()
  .trim()
  .max(2000)
  .refine((value) => httpUrlPattern.test(value), "sourceUrl must be an http(s) URL.")
  .nullable();
const imageNameField = z.string().trim().max(2000).nullable();

const CreateRecipeSchema = z.object({
  title: titleField,
  summary: summaryField.optional(),
  ingredients: ingredientsField.optional().default([]),
  instructions: instructionsField.optional().default([]),
  servings: servingsField.optional(),
  prepMinutes: prepMinutesField.optional(),
  cookMinutes: cookMinutesField.optional(),
  // Optional and omittable, same as every other nullable field here — most
  // recipes (especially anything created before this field existed) have no
  // photo at all. See `photoBase64Field`'s own doc comment for the size cap.
  photoBase64: photoBase64Field.optional(),
  sourceUrl: sourceUrlField.optional(),
  imageName: imageNameField.optional(),
});

// PATCH accepts the same fields but every one is optional with NO default:
// an omitted field is left unchanged, an explicitly-included one (even
// `ingredients: []`) replaces the current value. See the PATCH handler
// below for how `ingredients` specifically is handled (delete-and-recreate,
// not diffed).
const UpdateRecipeSchema = z.object({
  title: titleField.optional(),
  summary: summaryField.optional(),
  ingredients: ingredientsField.optional(),
  instructions: instructionsField.optional(),
  servings: servingsField.optional(),
  prepMinutes: prepMinutesField.optional(),
  cookMinutes: cookMinutesField.optional(),
  // Omitted -> unchanged; explicit `null` -> clears the photo (e.g. the
  // owner removes it in the editor); a base64 string -> replaces it. Same
  // "omitted vs. explicit null" distinction `summary`/`servings`/etc. above
  // already rely on (see the PATCH handler's `data.X !== undefined` checks).
  photoBase64: photoBase64Field.optional(),
  sourceUrl: sourceUrlField.optional(),
  imageName: imageNameField.optional(),
});

// POST /recipe-library
// Body: { title, summary?, ingredients: [{ name, quantity?, unit? }],
// instructions: string[], servings?, prepMinutes?, cookMinutes?,
// photoBase64? }. Owner is always the caller; a new recipe always starts
// PRIVATE (only sharing it via POST /:recipeId/share moves it to SHARED).
router.post("/", asyncHandler(async (req, res) => {
  const parsed = CreateRecipeSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const {
    title, summary, ingredients, instructions, servings, prepMinutes, cookMinutes, photoBase64,
    sourceUrl, imageName,
  } = parsed.data;

  const recipe = await prisma.recipe.create({
    data: {
      ownerId: req.userId,
      title,
      summary: summary ?? null,
      instructions,
      servings: servings ?? null,
      prepMinutes: prepMinutes ?? null,
      cookMinutes: cookMinutes ?? null,
      photoBase64: photoBase64 ?? null,
      sourceUrl: sourceUrl ?? null,
      imageName: imageName ?? null,
      ingredients: {
        create: ingredients.map((ingredient, index) => ({
          name: ingredient.name,
          quantity: ingredient.quantity ?? null,
          unit: ingredient.unit ?? null,
          sortIndex: index,
        })),
      },
    },
    include: RECIPE_INGREDIENTS_INCLUDE,
  });

  res.status(201).json({ recipe: serializeRecipe(recipe) });
}));

// GET /recipe-library/mine — every recipe the caller owns, regardless of
// visibility/sharing state.
router.get("/mine", asyncHandler(async (req, res) => {
  const recipes = await prisma.recipe.findMany({
    where: { ownerId: req.userId },
    include: RECIPE_INGREDIENTS_INCLUDE,
    orderBy: { createdAt: "desc" },
  });
  res.json({ recipes: recipes.map(serializeRecipe) });
}));

// GET /recipe-library/shared-with-me — every recipe shared directly with
// the caller, or shared with any group the caller belongs to. Returns one
// entry PER SHARE (not deduped per-recipe): if the same recipe reached the
// caller two ways — shared directly *and* via a group, or via two different
// groups — it appears twice, each time annotated with that specific share's
// `sharedBy`/`sharedWithGroup`. Kept this simple for v1 rather than merging
// multiple shares of the same recipe into one entry with a list of sources.
router.get("/shared-with-me", asyncHandler(async (req, res) => {
  const memberships = await prisma.groupMembership.findMany({
    where: { userId: req.userId },
    select: { groupId: true },
  });
  const myGroupIds = memberships.map((m) => m.groupId);

  const shares = await prisma.recipeShare.findMany({
    where: {
      OR: [
        { sharedWithUserId: req.userId },
        ...(myGroupIds.length ? [{ sharedWithGroupId: { in: myGroupIds } }] : []),
      ],
    },
    include: {
      recipe: { include: RECIPE_INGREDIENTS_INCLUDE },
      sharedByUser: true,
      sharedWithGroup: true,
    },
    orderBy: { createdAt: "desc" },
  });

  res.json({
    recipes: shares.map((share) => ({
      ...serializeRecipe(share.recipe),
      share: {
        id: share.id,
        sharedAt: share.createdAt,
        sharedBy: publicUser(share.sharedByUser),
        sharedWithGroup: share.sharedWithGroup
          ? { id: share.sharedWithGroup.id, name: share.sharedWithGroup.name }
          : null,
      },
    })),
  });
}));

// GET /recipe-library/master — every PUBLIC (library-published) recipe,
// newest first, visible to ANY signed-in user regardless of friend/group
// relationship to the publisher — direct user request: "Library is a
// master recipe list for all users to see." Registered before the generic
// GET /:recipeId below so Express doesn't swallow "master" as a
// `:recipeId` value.
//
// `addedBy` is `null` when the publisher chose to stay anonymous
// (`publishedAnonymously` — see that column's own doc comment in
// prisma/schema.prisma and POST /:recipeId/publish below); the iOS client
// shows "Added anonymously" in that case rather than guessing at a name.
router.get("/master", asyncHandler(async (req, res) => {
  const recipes = await prisma.recipe.findMany({
    where: { visibility: "PUBLIC" },
    include: { ...RECIPE_INGREDIENTS_INCLUDE, owner: true },
    orderBy: { createdAt: "desc" },
  });
  res.json({
    recipes: recipes.map((recipe) => ({
      ...serializeRecipe(recipe),
      addedBy: recipe.publishedAnonymously ? null : publicUser(recipe.owner),
    })),
  });
}));

// Loads a recipe and figures out whether the caller may see it: the owner,
// a direct share target, or a member of a group it's shared with. Returns
// `{ recipe: null }` for a nonexistent recipe (caller should 404) or
// `{ recipe, allowed: false }` for one that exists but the caller can't see
// (caller should 403) — kept as one shared helper so GET/PATCH/DELETE-style
// ownership checks don't each re-derive this differently.
async function loadRecipeForViewer(recipeId, userId) {
  const recipe = await prisma.recipe.findUnique({
    where: { id: recipeId },
    include: RECIPE_INGREDIENTS_INCLUDE,
  });
  if (!recipe) return { recipe: null, allowed: false };
  if (recipe.ownerId === userId) return { recipe, allowed: true };
  // A PUBLIC (library-published) recipe is visible to every signed-in
  // user, not just an owner/share relationship — see the RecipeVisibility
  // doc comment in prisma/schema.prisma.
  if (recipe.visibility === "PUBLIC") return { recipe, allowed: true };

  const directShare = await prisma.recipeShare.findFirst({
    where: { recipeId, sharedWithUserId: userId },
  });
  if (directShare) return { recipe, allowed: true };

  const groupShare = await prisma.recipeShare.findFirst({
    where: {
      recipeId,
      sharedWithGroupId: { not: null },
      sharedWithGroup: { memberships: { some: { userId } } },
    },
  });
  return { recipe, allowed: Boolean(groupShare) };
}

// GET /recipe-library/:recipeId — full detail including ingredients. 403
// unless the caller is the owner, a direct share target, or a member of a
// group it's shared with (404 if the recipe doesn't exist at all).
router.get("/:recipeId", asyncHandler(async (req, res) => {
  const { recipe, allowed } = await loadRecipeForViewer(req.params.recipeId, req.userId);
  if (!recipe) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (!allowed) {
    return res.status(403).json({ error: "You don't have access to this recipe." });
  }
  res.json({ recipe: serializeRecipe(recipe) });
}));

// PATCH /recipe-library/:recipeId — owner only. Any field present in the
// body replaces the current value; an omitted field is left unchanged.
router.patch("/:recipeId", asyncHandler(async (req, res) => {
  const existing = await prisma.recipe.findUnique({ where: { id: req.params.recipeId } });
  if (!existing) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (existing.ownerId !== req.userId) {
    return res.status(403).json({ error: "Only the recipe's owner can edit it." });
  }

  const parsed = UpdateRecipeSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  const scalarUpdates = {};
  if (data.title !== undefined) scalarUpdates.title = data.title;
  if (data.summary !== undefined) scalarUpdates.summary = data.summary;
  if (data.instructions !== undefined) scalarUpdates.instructions = data.instructions;
  if (data.servings !== undefined) scalarUpdates.servings = data.servings;
  if (data.prepMinutes !== undefined) scalarUpdates.prepMinutes = data.prepMinutes;
  if (data.cookMinutes !== undefined) scalarUpdates.cookMinutes = data.cookMinutes;
  if (data.photoBase64 !== undefined) scalarUpdates.photoBase64 = data.photoBase64;
  if (data.sourceUrl !== undefined) scalarUpdates.sourceUrl = data.sourceUrl;
  if (data.imageName !== undefined) scalarUpdates.imageName = data.imageName;

  // Ingredients are replaced wholesale — delete every existing
  // RecipeIngredient row for this recipe and recreate from the incoming
  // array — rather than diffing/patching individual rows. Incoming
  // ingredient entries have no stable id to match against an existing row
  // by, so a diff would have to guess correspondence by name/position
  // anyway; delete-and-recreate inside one transaction is simplest-correct
  // and still atomic (a failure rolls back to the old ingredient list, not
  // a half-replaced one). Only downside: ingredient row ids change on every
  // edit that touches ingredients, which is fine since nothing references
  // a RecipeIngredient id from outside this file.
  const recipe = await prisma.$transaction(async (tx) => {
    if (data.ingredients !== undefined) {
      await tx.recipeIngredient.deleteMany({ where: { recipeId: existing.id } });
    }
    return tx.recipe.update({
      where: { id: existing.id },
      data: {
        ...scalarUpdates,
        ...(data.ingredients !== undefined
          ? {
              ingredients: {
                create: data.ingredients.map((ingredient, index) => ({
                  name: ingredient.name,
                  quantity: ingredient.quantity ?? null,
                  unit: ingredient.unit ?? null,
                  sortIndex: index,
                })),
              },
            }
          : {}),
      },
      include: RECIPE_INGREDIENTS_INCLUDE,
    });
  });

  res.json({ recipe: serializeRecipe(recipe) });
}));

// DELETE /recipe-library/:recipeId — owner only. Cascades to its
// RecipeIngredient and RecipeShare rows (see the `onDelete: Cascade`s in
// prisma/schema.prisma).
//
// Refuses to delete a recipe that's still decided into any group's shared
// plan (`PlannedMeal.recipeId`) — direct user report: `PlannedMeal.recipeId`
// is `onDelete: SetNull` specifically so a group's meal-plan *history*
// survives an unrelated recipe cleanup elsewhere (see that model's own doc
// comment in schema.prisma), but nulling the reference on a plan entry
// that's still current/upcoming just leaves it looking broken ("Planned"/
// an unattributed row) with no way to tell what it used to be — "should
// never delete a recipe... if it's already in a plan." A `MealSuggestion`
// (a proposed candidate, not yet adopted into the plan) doesn't block this
// the same way; only an actually-decided `PlannedMeal` does.
router.delete("/:recipeId", asyncHandler(async (req, res) => {
  const existing = await prisma.recipe.findUnique({ where: { id: req.params.recipeId } });
  if (!existing) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (existing.ownerId !== req.userId) {
    return res.status(403).json({ error: "Only the recipe's owner can delete it." });
  }
  const plannedMealCount = await prisma.plannedMeal.count({ where: { recipeId: existing.id } });
  if (plannedMealCount > 0) {
    return res.status(409).json({
      error: "This recipe is still in a meal plan and can't be deleted. Remove it from the plan first.",
    });
  }
  await prisma.recipe.delete({ where: { id: existing.id } });
  res.status(204).end();
}));

// Body must set exactly one of userId/groupId — Prisma/Postgres can't
// cleanly express "exactly one of these two nullable columns" as a schema
// constraint (see the RecipeShare doc comment in prisma/schema.prisma), so
// `.strict()` plus the explicit XOR check right after parsing enforces it
// here instead.
const ShareSchema = z
  .object({
    userId: z.string().uuid().optional(),
    groupId: z.string().uuid().optional(),
  })
  .strict();

// POST /recipe-library/:recipeId/share
// Body: { userId } or { groupId } (exactly one). Owner only — even someone
// this recipe is already shared with can't re-share it further; that's the
// owner's call alone in v1. Sharing to a userId requires that user to be an
// accepted friend of the owner (same anti-stranger rule as group invites/
// creation in routes/groups.js); sharing to a groupId requires the owner to
// be a member of that group. Moves visibility PRIVATE -> SHARED if it
// wasn't already; 409 if already shared with that exact user/group.
router.post("/:recipeId/share", asyncHandler(async (req, res) => {
  const recipe = await prisma.recipe.findUnique({ where: { id: req.params.recipeId } });
  if (!recipe) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (recipe.ownerId !== req.userId) {
    return res.status(403).json({ error: "Only the recipe's owner can share it." });
  }

  const parsed = ShareSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Provide either userId or groupId." });
  }
  const { userId, groupId } = parsed.data;
  if ((userId && groupId) || (!userId && !groupId)) {
    return res.status(400).json({ error: "Provide exactly one of userId or groupId, not both or neither." });
  }

  if (userId) {
    if (userId === req.userId) {
      return res.status(400).json({ error: "You can't share a recipe with yourself." });
    }
    if (!(await isAcceptedFriend(req.userId, userId))) {
      return res.status(400).json({ error: "You can only share recipes with your accepted friends." });
    }
    const existingShare = await prisma.recipeShare.findFirst({
      where: { recipeId: recipe.id, sharedWithUserId: userId },
    });
    if (existingShare) {
      return res.status(409).json({ error: "Already shared with that person." });
    }
  } else {
    const membership = await membershipFor(groupId, req.userId);
    if (!membership) {
      return res.status(400).json({ error: "You're not a member of that group." });
    }
    const existingShare = await prisma.recipeShare.findFirst({
      where: { recipeId: recipe.id, sharedWithGroupId: groupId },
    });
    if (existingShare) {
      return res.status(409).json({ error: "Already shared with that group." });
    }
  }

  const [share] = await prisma.$transaction([
    prisma.recipeShare.create({
      data: {
        recipeId: recipe.id,
        sharedByUserId: req.userId,
        sharedWithUserId: userId ?? null,
        sharedWithGroupId: groupId ?? null,
      },
    }),
    prisma.recipe.update({
      where: { id: recipe.id },
      data: recipe.visibility === "PRIVATE" ? { visibility: "SHARED" } : {},
    }),
  ]);

  res.status(201).json({ share });

  // Push to whoever this just got shared with — same "after the response,
  // fire-and-forget" shape as routes/friends.js's/routes/groups.js's own
  // pushes (see routes/friends.js's POST /request doc comment for the full
  // reasoning). Direct user report that sharing a recipe never notified the
  // recipient(s) at all. A group share pushes to every member except the
  // sharer themselves — same "everyone but me" scope `GroupSharedGroceryListView`'s
  // suggestion queue and every other group-wide notice in this app already
  // uses.
  const me = await prisma.user.findUnique({ where: { id: req.userId } });
  const sharerName = me?.displayName || me?.phoneNumber || "Someone";
  if (userId) {
    const deviceTokens = (await prisma.deviceToken.findMany({
      where: { userId },
      select: { token: true },
    })).map((row) => row.token);
    await sendPush({
      deviceTokens,
      title: "Recipe Shared With You",
      body: `${sharerName} shared "${recipe.title}" with you on Home Eats.`,
      payload: { type: "recipeShare", recipeId: recipe.id },
    });
  } else {
    const [members, group] = await Promise.all([
      prisma.groupMembership.findMany({
        where: { groupId, userId: { not: req.userId } },
        select: { userId: true },
      }),
      prisma.group.findUnique({ where: { id: groupId }, select: { name: true } }),
    ]);
    const deviceTokens = (await prisma.deviceToken.findMany({
      where: { userId: { in: members.map((m) => m.userId) } },
      select: { token: true },
    })).map((row) => row.token);
    await sendPush({
      deviceTokens,
      title: "Recipe Shared With Your Group",
      body: `${sharerName} shared "${recipe.title}" with "${group?.name || "your group"}" on Home Eats.`,
      payload: { type: "recipeShare", recipeId: recipe.id, groupId },
    });
  }
}));

// DELETE /recipe-library/:recipeId/share/:shareId — un-share, owner only.
// Deliberately does NOT revert visibility back to PRIVATE even if this was
// the recipe's last remaining share — re-deriving visibility from "is there
// still at least one share row" on every unshare is a reasonable feature,
// but a non-obvious design call (does removing the last share of many
// count differently than removing the only one ever made? what if the
// owner explicitly wants to keep showing it as SHARED for their own
// reference?) that's simplest left explicit for v1: visibility only ever
// moves PRIVATE -> SHARED automatically, never back, and the owner can
// always PATCH it themselves if this app grows a way to set visibility
// directly later.
router.delete("/:recipeId/share/:shareId", asyncHandler(async (req, res) => {
  const recipe = await prisma.recipe.findUnique({ where: { id: req.params.recipeId } });
  if (!recipe) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (recipe.ownerId !== req.userId) {
    return res.status(403).json({ error: "Only the recipe's owner can unshare it." });
  }

  const share = await prisma.recipeShare.findUnique({ where: { id: req.params.shareId } });
  if (!share || share.recipeId !== recipe.id) {
    return res.status(404).json({ error: "Share not found." });
  }

  await prisma.recipeShare.delete({ where: { id: share.id } });
  res.status(204).end();
}));

const PublishSchema = z.object({ anonymous: z.boolean() }).strict();

// POST /recipe-library/:recipeId/publish
// Body: { anonymous } — owner only. Publishes this recipe to the master
// library (visibility -> PUBLIC, one-way, same "never reverts" precedent
// as PRIVATE -> SHARED — see DELETE /:recipeId/share/:shareId's own doc
// comment) — direct user request, with the publisher choosing right at
// publish time whether to be credited ("Added by <name>") or stay
// anonymous. Callable again on an already-PUBLIC recipe purely to flip
// that choice (there's only ever one "published" state per recipe to
// track, unlike the many-rows-per-recipe RecipeShare model, so there's no
// meaningful "already published" 409 the way POST /:recipeId/share has for
// a duplicate share target).
router.post("/:recipeId/publish", asyncHandler(async (req, res) => {
  const recipe = await prisma.recipe.findUnique({ where: { id: req.params.recipeId } });
  if (!recipe) {
    return res.status(404).json({ error: "Recipe not found." });
  }
  if (recipe.ownerId !== req.userId) {
    return res.status(403).json({ error: "Only the recipe's owner can add it to the library." });
  }

  const parsed = PublishSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }

  const updated = await prisma.recipe.update({
    where: { id: recipe.id },
    data: { visibility: "PUBLIC", publishedAnonymously: parsed.data.anonymous },
  });
  res.json({ recipe: serializeRecipe(updated) });
}));

module.exports = router;
