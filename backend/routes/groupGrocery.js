// A group's shared grocery list (Phase 3) — one list per group, same
// "belongs to the group outright" relationship as the meal plan in
// routes/groupMealPlan.js. Mounted at /groups/:groupId/grocery in
// index.js, behind requireAuth; every route here re-checks membership
// itself (never trusts the mount path alone), same rigor as the rest of
// this codebase's group routes.
//
// Roles here are more fine-grained than the meal plan's route-level
// MANAGER/PARTICIPANT split — see each route's own comment below for the
// specific, sometimes field-level, reasoning (POST's section restriction,
// PATCH's field-by-field split, DELETE's section-dependent rule).
//
// Phase 4 ("My Layout" / history): sibling router
// routes/groupGroceryAisles.js (mounted at .../grocery/aisles) adds the
// group-scoped counterpart of the local `StoreAisle`/`ItemAisleAssignment`
// models — see that file's own doc comment, and prisma/schema.prisma's
// GroupStoreAisle/GroupGroceryHistoryEntry doc comments for the full
// data-model reasoning. (A third Phase-4 sibling, routes/groupGroceryStaples.js —
// a group-scoped standing "staples" template list — was removed outright per
// user feedback; the pre-existing `GroupGrocerySection.STAPLES` value this
// file's own `section` field can hold is a separate, unrelated concept — a
// tag on one specific line already on the live list, not that removed
// feature — and stays exactly as it was.)
// The item-to-aisle assignment itself (`aisleId`/`aisleManuallySet`) folds
// into this file's own PATCH /:id below instead of living in the aisles
// router, since it's a field on *this* file's model — see that route's
// comment for why it's open to any member. The "history" (past-groceries
// quick-add) endpoint also lives here rather than in a Phase-4-only file,
// since its one write trigger is a transition inside this file's own PATCH
// /:id handler — see GroupGroceryHistoryEntry's doc comment in
// prisma/schema.prisma for why it's a small durable table rather than a
// query derived from this table.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router({ mergeParams: true });

// Duplicated rather than imported — see the same note in
// routes/groupMealPlan.js.
function membershipFor(groupId, userId) {
  return prisma.groupMembership.findUnique({
    where: { userId_groupId: { userId, groupId } },
  });
}

async function requireMembership(req, res) {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    res.status(403).json({ error: "You're not a member of this group." });
    return null;
  }
  req.groupMembership = membership;
  return membership;
}

function isManager(membership) {
  return membership.role === "MANAGER";
}

function serializeItem(item) {
  return {
    id: item.id,
    groupId: item.groupId,
    name: item.name,
    category: item.category,
    section: item.section,
    quantityText: item.quantityText,
    quantityCount: item.quantityCount,
    isChecked: item.isChecked,
    orderIndex: item.orderIndex,
    // "My Layout" placement — see prisma/schema.prisma's GroupGroceryItem
    // doc comment. A client should ignore `aisleId` entirely while
    // `aisleManuallySet` is false and instead fall back to whichever
    // GroupStoreAisle has `linkedCategory === category`, exactly like the
    // local `resolvedAisleID` does — this route never computes that
    // fallback itself (same "client groups/filters locally" philosophy as
    // GET / not pre-splitting by category/section).
    aisleId: item.aisleId,
    aisleManuallySet: item.aisleManuallySet,
    addedByUserId: item.addedByUserId,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  };
}

// Lowercased/trimmed dedupe key for GroupGroceryHistoryEntry — deliberately
// simpler than the iOS canonicalizer's pluralization-aware
// `GroceryListBuilder.canonicalKey` (see that model's doc comment in
// prisma/schema.prisma for why porting that logic server-side isn't worth
// it here): this only needs to stop the exact same typed name (modulo case/
// whitespace) from creating two history rows, not to unify "carrot"/
// "carrots" the way the recipe-ingredient pipeline does.
function normalizeHistoryName(name) {
  return name.trim().toLowerCase();
}

const GROCERY_CATEGORIES = [
  "PRODUCE",
  "DAIRY_AND_EGGS",
  "MEAT_AND_SEAFOOD",
  "BAKERY",
  "PANTRY",
  "FROZEN",
  "BEVERAGES",
  "SNACKS",
  "HOUSEHOLD",
  "OTHER",
];
const GROCERY_SECTIONS = ["SUGGESTED", "THIS_WEEK", "STAPLES"];

// GET /groups/:groupId/grocery — everything for the group; the client
// groups/filters locally (by category/section), same "no server-side
// filtering at household scale" choice as GET .../meal-plan.
router.get("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const items = await prisma.groupGroceryItem.findMany({
    where: { groupId: req.params.groupId },
    orderBy: [{ category: "asc" }, { orderIndex: "asc" }],
  });
  res.json({ items: items.map(serializeItem) });
}));

// GET /groups/:groupId/grocery/history — "things this group has bought
// before," for one-tap re-adding (the group-scoped counterpart of the
// local "From Your Past Groceries" section). Sourced from
// GroupGroceryHistoryEntry, not a live query over GroupGroceryItem — see
// that model's doc comment in prisma/schema.prisma for why a derived query
// can't correctly serve this (in short: a bought item's row is routinely
// deleted once it's off the list, which would make a derived query lose
// exactly the names this endpoint most needs to remember). Each row here
// was written once, automatically, the moment some GroupGroceryItem with
// that name was first checked off (see PATCH /:id below) — nothing here
// needs its own create/update/delete endpoints; it's a read-only catalog
// that fills itself in from ordinary list use, same as the local one.
// Any member may read it — same "routine, not a planning decision" bucket
// as the rest of this file's any-member actions.
router.get("/history", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const entries = await prisma.groupGroceryHistoryEntry.findMany({
    where: { groupId: req.params.groupId },
    orderBy: { name: "asc" },
  });
  res.json({
    items: entries.map((entry) => ({
      name: entry.name,
      category: entry.category,
      addedAt: entry.createdAt,
    })),
  });
}));

const CreateItemSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200),
    category: z.enum(GROCERY_CATEGORIES),
    section: z.enum(GROCERY_SECTIONS),
    quantityText: z.string().trim().max(200).optional().default(""),
    quantityCount: z.number().int().min(1).max(999).optional().default(1),
    orderIndex: z.number().finite().optional().default(0),
  })
  .strict();

// POST /groups/:groupId/grocery — any member can call this, but with a
// role-gated constraint on `section`: a PARTICIPANT may only create with
// `section: SUGGESTED` (this is the "participant suggests an item" path,
// mirroring the meal plan's suggestion flow) — a PARTICIPANT trying to set
// THIS_WEEK or STAPLES directly is rejected with 403 (they're a member and
// the request is otherwise well-formed; they're just not allowed to skip
// the suggest-then-accept step, which is a permissions problem, not a
// validation one — consistent with this file's other 403-for-role-denied/
// 400-for-malformed-input split). A MANAGER may create with any section —
// this is the "manager adds directly onto the real list" path.
router.post("/", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;

  const parsed = CreateItemSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  if (!isManager(membership) && data.section !== "SUGGESTED") {
    return res.status(403).json({ error: "Only a group manager can add an item directly to the list — suggest it instead." });
  }

  const item = await prisma.groupGroceryItem.create({
    data: {
      groupId: req.params.groupId,
      name: data.name,
      category: data.category,
      section: data.section,
      quantityText: data.quantityText,
      quantityCount: data.quantityCount,
      orderIndex: data.orderIndex,
      addedByUserId: req.userId,
    },
  });

  res.status(201).json({ item: serializeItem(item) });
}));

// PATCH /groups/:groupId/grocery/:id/accept — MANAGER only. Moves a
// SUGGESTED item to THIS_WEEK — the accept half of the participant-suggests
// / manager-accepts flow (there's no reject endpoint: rejecting a
// suggestion is just DELETE, same corrected semantics as the local app's
// own "reject deletes the row outright" fix — see the GroupGrocerySection
// doc comment in prisma/schema.prisma and the DELETE route below).
router.patch("/:id/accept", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;
  if (!isManager(membership)) {
    return res.status(403).json({ error: "Only a group manager can accept a suggested item." });
  }

  const existing = await prisma.groupGroceryItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Grocery item not found." });
  }
  if (existing.section !== "SUGGESTED") {
    return res.status(409).json({ error: "Only a suggested item can be accepted." });
  }

  const item = await prisma.groupGroceryItem.update({
    where: { id: existing.id },
    data: { section: "THIS_WEEK" },
  });
  res.json({ item: serializeItem(item) });
}));

// PATCH /groups/:groupId/grocery/:id — general field update. Deliberately
// asymmetric, field by field, rather than one role gate for the whole
// route:
//
// - `isChecked`/`orderIndex`/`quantityCount`: any member may change these.
//   Checking an item off (shopping), reordering it (tidying the list), or
//   adjusting how many to get is routine day-to-day use of an
//   already-decided list, not a planning decision — the same reasoning the
//   meal plan gives PARTICIPANTs a vote/suggest but not a decide action
//   doesn't apply here, since nothing about *using* the list changes what's
//   actually on it.
// - `name`/`category`/`quantityText`/`section`: MANAGER only. These change
//   what's actually on the list or how it's organized/categorized — more
//   like editing the plan itself (the same category POST's section rule
//   already gates who can add straight onto the real list) — so they get
//   the same MANAGER-only treatment as adding an item directly.
// - `aisleId` (Phase 4, "My Layout" placement): any member, same bucket as
//   isChecked/orderIndex. Moving an item to a different aisle doesn't
//   change what's on the list or how it's categorized (`category` stays
//   whatever it was) — it only changes where this one shopper's copy of
//   the list puts it while walking the store, the exact "routine,
//   day-to-day use" carve-out this split already draws on for
//   isChecked/orderIndex. Sending `aisleId` at all (including explicitly
//   `null`) always sets `aisleManuallySet: true` too — see
//   GroupGroceryItem's doc comment in prisma/schema.prisma for why `null`
//   has to be a real, persisted choice ("Unsorted") rather than
//   indistinguishable from "never touched". A given `aisleId` must name a
//   `GroupStoreAisle` belonging to this same group (400 otherwise, same
//   "must reference something the caller can actually use" shape as
//   groupMealPlan.js's `recipeId` check).
//
// A PARTICIPANT's request touching only isChecked/orderIndex/aisleId
// succeeds; one that ALSO includes any of the MANAGER-only fields is
// rejected outright (400) rather than silently applying the allowed subset
// and dropping the rest — so a client always gets an explicit signal
// instead of a partially-applied update it might not notice.
const UpdateItemSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200).optional(),
    category: z.enum(GROCERY_CATEGORIES).optional(),
    quantityText: z.string().trim().max(200).optional(),
    section: z.enum(GROCERY_SECTIONS).optional(),
    isChecked: z.boolean().optional(),
    orderIndex: z.number().finite().optional(),
    quantityCount: z.number().int().min(1).max(999).optional(),
    aisleId: z.string().uuid().nullable().optional(),
  })
  .strict();

const MANAGER_ONLY_FIELDS = ["name", "category", "quantityText", "section"];

router.patch("/:id", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;

  const parsed = UpdateItemSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  if (!isManager(membership)) {
    const touchedManagerOnlyField = MANAGER_ONLY_FIELDS.find((field) => data[field] !== undefined);
    if (touchedManagerOnlyField) {
      return res.status(403).json({
        error: `Only a group manager can change ${touchedManagerOnlyField}. Members can update isChecked, orderIndex, and aisleId.`,
      });
    }
  }

  const existing = await prisma.groupGroceryItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Grocery item not found." });
  }

  // `"aisleId" in req.body` (via `!== undefined` on the parsed result,
  // since zod's `.optional()` maps a missing key to `undefined` but leaves
  // an explicit `null` alone) is what lets a caller distinguish "don't
  // touch aisle placement" from "explicitly set it to Unsorted" — see the
  // route's own comment above.
  if (data.aisleId !== undefined && data.aisleId !== null) {
    const aisle = await prisma.groupStoreAisle.findUnique({ where: { id: data.aisleId } });
    if (!aisle || aisle.groupId !== req.params.groupId) {
      return res.status(400).json({ error: "aisleId must reference an aisle that exists in this group." });
    }
  }

  const updates = {};
  if (data.name !== undefined) updates.name = data.name;
  if (data.category !== undefined) updates.category = data.category;
  if (data.quantityText !== undefined) updates.quantityText = data.quantityText;
  if (data.section !== undefined) updates.section = data.section;
  if (data.isChecked !== undefined) updates.isChecked = data.isChecked;
  if (data.orderIndex !== undefined) updates.orderIndex = data.orderIndex;
  if (data.quantityCount !== undefined) updates.quantityCount = data.quantityCount;
  if (data.aisleId !== undefined) {
    updates.aisleId = data.aisleId;
    updates.aisleManuallySet = true;
  }

  // Recording history is a side effect of THIS update, not a separate
  // request, so it has to land in the same transaction as the item update
  // itself — otherwise a crash between the two could update isChecked
  // without ever recording the history entry. `becameChecked` is computed
  // from `existing` (fetched above, before this update) vs. the new value,
  // exactly mirroring the local `GroceryItemRow.setChecked` -> `guard
  // checked else { return }` -> `recordAsHistorical()` trigger: only a
  // false -> true transition counts, so unchecking, or an update that
  // doesn't touch isChecked at all, never (re)writes a history row.
  const becameChecked = data.isChecked === true && existing.isChecked === false;

  const item = await prisma.$transaction(async (tx) => {
    const updated = await tx.groupGroceryItem.update({ where: { id: existing.id }, data: updates });
    if (becameChecked) {
      const normalizedName = normalizeHistoryName(updated.name);
      // Upsert, not create: a name already known (this group has bought
      // "milk" before, checked off again this time) is a no-op here rather
      // than a unique-constraint error, matching the local
      // `recordAsHistorical`'s own `guard !alreadyKnown else { return }`.
      await tx.groupGroceryHistoryEntry.upsert({
        where: { groupId_normalizedName: { groupId: req.params.groupId, normalizedName } },
        update: {},
        create: {
          groupId: req.params.groupId,
          name: updated.name,
          normalizedName,
          category: updated.category,
        },
      });
    }
    return updated;
  });

  res.json({ item: serializeItem(item) });
}));

// DELETE /groups/:groupId/grocery/:id — the allowed-caller rule depends on
// the item's CURRENT section at delete time:
//
// - SUGGESTED: removing it is rejecting the suggestion — same rule as
//   withdrawing/removing a meal suggestion (routes/groupMealPlan.js):
//   MANAGER, or the original suggester of that specific item.
// - THIS_WEEK / STAPLES: removing it is routine list maintenance ("we
//   bought it" or "we don't need it after all") — any member may delete
//   it, same reasoning as isChecked/orderIndex in PATCH above.
router.delete("/:id", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;

  const existing = await prisma.groupGroceryItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Grocery item not found." });
  }

  if (existing.section === "SUGGESTED") {
    if (!isManager(membership) && existing.addedByUserId !== req.userId) {
      return res
        .status(403)
        .json({ error: "Only a group manager or the original suggester can remove a suggested item." });
    }
  }
  // THIS_WEEK / STAPLES: any member may delete — no further check needed.

  await prisma.groupGroceryItem.delete({ where: { id: existing.id } });
  res.status(204).end();
}));

module.exports = router;
