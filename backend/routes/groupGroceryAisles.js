// A group's "My Layout" aisles (Phase 4) — the group-scoped counterpart of
// the local `StoreAisle` model, letting a household lay its shared grocery
// list out to match how their actual store is organized, independent of
// the fixed `GroceryCategory` list. See GroupStoreAisle's doc comment in
// prisma/schema.prisma for the full data-model reasoning (including the
// default-seeding behavior below) and backend/README.md's "Group grocery
// list" section for the documented contract.
//
// Mounted at /groups/:groupId/grocery/aisles in index.js, behind
// requireAuth, BEFORE the more general /groups/:groupId/grocery mount —
// same "specific prefix before general prefix" mount order as every other
// nested group router in this file's family, and every route here
// re-checks membership itself regardless (never trusts the mount path
// alone), same rigor as routes/groupGrocery.js.
//
// Authorization: every route below is open to ANY member, not MANAGER
// only. This is a deliberate call, not the default — see the comment on
// each route for the specific reasoning, but in short: an aisle is a
// display/organization construct for walking the store, not a decision
// about what's actually being bought (that stays MANAGER-gated on
// GroupGroceryItem's own name/category/quantityText/section, unchanged by
// this file). The local app itself doesn't gate aisle management at all
// (it's single-user), and item-to-aisle placement in
// routes/groupGrocery.js's PATCH /:id is already any-member for the same
// "routine organizing, not planning" reasoning this file extends to the
// aisles themselves.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router({ mergeParams: true });

// Duplicated rather than imported — see the same note in
// routes/groupMealPlan.js and routes/groupGrocery.js.
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
  return membership;
}

function serializeAisle(aisle) {
  return {
    id: aisle.id,
    groupId: aisle.groupId,
    name: aisle.name,
    sortIndex: aisle.sortIndex,
    linkedCategory: aisle.linkedCategory,
    createdAt: aisle.createdAt,
  };
}

// Same category list/order as routes/groupGrocery.js's GROCERY_CATEGORIES —
// duplicated for the same "each route file is self-contained" reason, kept
// in the exact same order (which matches the iOS `GroceryCategory` enum's
// declaration order, and therefore its `sortIndex`/`allCases` order too) so
// the seeded aisles below land in the same walking order iOS would give
// them.
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

// Mirrors `GroceryCategory.displayName` in
// HomeEats/Models/GroceryCategory.swift exactly — this is the one piece of
// display logic this backend duplicates from iOS (everywhere else, display
// strings/symbols stay entirely client-side, per the GroupGroceryItem doc
// comment's "guess/symbolName/sortIndex display logic stays client-side"
// precedent) because the seeded aisle *rows* need a real `name` value the
// moment they're created, not just at render time.
const CATEGORY_DISPLAY_NAMES = {
  PRODUCE: "Produce",
  DAIRY_AND_EGGS: "Dairy & Eggs",
  MEAT_AND_SEAFOOD: "Meat & Seafood",
  BAKERY: "Bakery",
  PANTRY: "Pantry",
  FROZEN: "Frozen",
  BEVERAGES: "Beverages",
  SNACKS: "Snacks",
  HOUSEHOLD: "Household",
  OTHER: "Other",
};

// Seeds this group's ten starter aisles — one per GroceryCategory, in
// GROCERY_CATEGORIES order — the FIRST time they're looked at for a group
// with zero GroupStoreAisle rows so far. See GroupStoreAisle's doc comment
// in prisma/schema.prisma for why this is lazily triggered by the first
// read rather than at group-creation time the way iOS's `SampleDataSeeder`
// seeds them at app-launch time. Idempotent and cheap after the first call,
// same "only runs while completely empty" guard as
// `seedDefaultLayoutAislesIfNeeded` — a household that's already added even
// one custom aisle of their own is never touched by this again.
async function ensureDefaultAislesSeeded(groupId) {
  const existingCount = await prisma.groupStoreAisle.count({ where: { groupId } });
  if (existingCount > 0) return;

  // `createMany` (not a loop of individual `create` calls) so this is one
  // round trip and, more importantly, can't leave a partially-seeded set of
  // aisles behind if it fails partway through.
  await prisma.groupStoreAisle.createMany({
    data: GROCERY_CATEGORIES.map((category, index) => ({
      groupId,
      name: CATEGORY_DISPLAY_NAMES[category],
      sortIndex: index,
      linkedCategory: category,
    })),
  });
}

// GET /groups/:groupId/grocery/aisles — every aisle for the group, sorted
// walking-order (lowest sortIndex first). Seeds the ten category-mirroring
// starter aisles first if this group has none yet — see
// ensureDefaultAislesSeeded above and GroupStoreAisle's doc comment in
// prisma/schema.prisma for why this is where that seeding happens.
router.get("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  await ensureDefaultAislesSeeded(req.params.groupId);

  const aisles = await prisma.groupStoreAisle.findMany({
    where: { groupId: req.params.groupId },
    orderBy: { sortIndex: "asc" },
  });
  res.json({ aisles: aisles.map(serializeAisle) });
}));

const CreateAisleSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200),
  })
  .strict();

// POST /groups/:groupId/grocery/aisles — any member (see this file's own
// doc comment for the authorization reasoning). Lands at the end of the
// group's current walking order, same "append, don't ask where" behavior
// as the local `AislesManagerView.addAisle`. A freshly created aisle is
// always a genuinely custom one — `linkedCategory` stays null, since the
// only aisles ever seeded with one are the ten starters from
// ensureDefaultAislesSeeded above.
router.post("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const parsed = CreateAisleSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }

  const maxSortIndex = await prisma.groupStoreAisle.aggregate({
    where: { groupId: req.params.groupId },
    _max: { sortIndex: true },
  });
  const nextSortIndex = (maxSortIndex._max.sortIndex ?? -1) + 1;

  const aisle = await prisma.groupStoreAisle.create({
    data: {
      groupId: req.params.groupId,
      name: parsed.data.name,
      sortIndex: nextSortIndex,
    },
  });
  res.status(201).json({ aisle: serializeAisle(aisle) });
}));

// PATCH /groups/:groupId/grocery/aisles/:id — rename and/or reposition.
// Any member — renaming/reordering a starter aisle works exactly the same
// as a fully custom one, same as the local `AislesManagerView` (tapping
// ANY row, starter or custom, opens the same rename alert; drag-reorder
// works on the whole list together). `linkedCategory` is never settable
// here — it's an internal marker only ensureDefaultAislesSeeded ever sets,
// same as iOS never exposing it as an editable field either.
const UpdateAisleSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200).optional(),
    sortIndex: z.number().finite().optional(),
  })
  .strict();

router.patch("/:id", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const parsed = UpdateAisleSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  const existing = await prisma.groupStoreAisle.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Aisle not found." });
  }

  const updates = {};
  if (data.name !== undefined) updates.name = data.name;
  if (data.sortIndex !== undefined) updates.sortIndex = data.sortIndex;

  const aisle = await prisma.groupStoreAisle.update({ where: { id: existing.id }, data: updates });
  res.json({ aisle: serializeAisle(aisle) });
}));

// DELETE /groups/:groupId/grocery/aisles/:id — any member, same reasoning
// as the rest of this file. Deleting a starter aisle is allowed too, same
// as the local app (see AislesManagerView's own doc comment: "renaming,
// reordering, or deleting one here works exactly the same as for a fully
// custom aisle").
//
// Runs as a transaction with a bulk reset of every GroupGroceryItem that
// was manually placed here: `aisleId` -> null AND `aisleManuallySet` ->
// false, not just `aisleId` -> null. That second half matters — see
// GroupGroceryItem's doc comment in prisma/schema.prisma: a plain
// `aisleId: null` with `aisleManuallySet` still true would read as
// "explicitly placed in Unsorted", which is not what happened here (the
// aisle it explicitly pointed at just stopped existing) — those items
// should fall back to their category's default aisle again, the same
// as if they'd never been explicitly placed at all. The FK's own
// `onDelete: SetNull` is only a backstop for this same half-reset, kept in
// the schema in case some future code path deletes a GroupStoreAisle
// without going through this route — see that field's doc comment.
router.delete("/:id", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const existing = await prisma.groupStoreAisle.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Aisle not found." });
  }

  await prisma.$transaction([
    prisma.groupGroceryItem.updateMany({
      where: { groupId: req.params.groupId, aisleId: existing.id },
      data: { aisleId: null, aisleManuallySet: false },
    }),
    prisma.groupStoreAisle.delete({ where: { id: existing.id } }),
  ]);

  res.status(204).end();
}));

module.exports = router;
