// A group's standing "staples" list (Phase 4) — the group-scoped
// counterpart of the local `StapleItem` model: recurring items the
// household always needs (milk, paper towels, ...), independent of any
// recipe, managed separately from whatever happens to be on the list this
// week. See GroupStapleItem's doc comment in prisma/schema.prisma for the
// full data-model reasoning, including how this is distinct from (and
// coexists with) the pre-existing `GroupGrocerySection.STAPLES` value on
// GroupGroceryItem.
//
// Mounted at /groups/:groupId/grocery/staples in index.js, behind
// requireAuth, BEFORE the more general /groups/:groupId/grocery mount —
// same mount-order reasoning as routes/groupGroceryAisles.js. Every route
// here re-checks membership itself, same rigor as the rest of this file's
// family.
//
// Authorization: every route below is open to ANY member, not MANAGER
// only — a deliberate call, weighed the same deliberate way as
// routes/groupGrocery.js's own asymmetric PATCH split, not a default.
// Reasoning:
//
//   1. A staple is a reference/template, not a decision about what's being
//      bought. Unlike GroupGroceryItem's `name`/`category`/`quantityText`/
//      `section` (MANAGER-only because they change what's actually on the
//      real list), creating or editing a GroupStapleItem has NO direct
//      effect on the live list at all — see `isActive`'s own comment below
//      for why toggling it doesn't feed anything automatically either.
//      There's simply no "real list" stake here for a MANAGER gate to be
//      protecting.
//   2. The household's own precedent already points this way: this
//      codebase's existing DELETE /groups/:groupId/grocery/:id rule (in
//      routes/groupGrocery.js) already lets ANY member delete a
//      `GroupGroceryItem` whose section is `STAPLES` — "routine list
//      maintenance", not a planning decision. A GroupStapleItem is a lower
//      stakes version of that same STAPLES concept (a template, not a live
//      list line), so gating it MORE tightly than the thing it's modeled
//      after would be the inconsistent choice, not this one.
//   3. It reads as closer to "routine household admin" than "meal
//      planning" — the digital version of anyone in the house adding to
//      the notepad on the fridge, not a decision that needs a household
//      "manager" to sign off on. Worst case for getting this wrong is
//      clutter (a duplicate or unwanted standing staple), not confusion
//      about what's actually being bought this week.
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

function serializeStaple(staple) {
  return {
    id: staple.id,
    groupId: staple.groupId,
    name: staple.name,
    category: staple.category,
    defaultQuantityText: staple.defaultQuantityText,
    isActive: staple.isActive,
    addedByUserId: staple.addedByUserId,
    createdAt: staple.createdAt,
  };
}

// Same category list as routes/groupGrocery.js's GROCERY_CATEGORIES —
// duplicated for the same "each route file is self-contained" reason
// documented there.
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

// GET /groups/:groupId/grocery/staples — every staple for the group
// (active and inactive alike — same as the local `StaplesManagerView`,
// which shows every `StapleItem` with a toggle, not just the active ones),
// sorted alphabetically like the local `@Query(sort: \StapleItem.name)`.
router.get("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const staples = await prisma.groupStapleItem.findMany({
    where: { groupId: req.params.groupId },
    orderBy: { name: "asc" },
  });
  res.json({ staples: staples.map(serializeStaple) });
}));

const CreateStapleSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200),
    category: z.enum(GROCERY_CATEGORIES),
    defaultQuantityText: z.string().trim().max(200).optional(),
    isActive: z.boolean().optional().default(true),
  })
  .strict();

// POST /groups/:groupId/grocery/staples — any member (see this file's own
// doc comment for the authorization reasoning).
router.post("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const parsed = CreateStapleSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  const staple = await prisma.groupStapleItem.create({
    data: {
      groupId: req.params.groupId,
      name: data.name,
      category: data.category,
      defaultQuantityText: data.defaultQuantityText ?? null,
      isActive: data.isActive,
      addedByUserId: req.userId,
    },
  });
  res.status(201).json({ staple: serializeStaple(staple) });
}));

// PATCH /groups/:groupId/grocery/staples/:id — any subset of
// {name, category, defaultQuantityText, isActive}, any member. Unlike
// routes/groupGrocery.js's PATCH /:id, there's no manager-only/any-member
// field split here — see this file's top doc comment for why every field
// on a staple gets the same "routine household admin" treatment, not just
// `isActive`.
//
// `isActive` ("include this the next time a grocery list is generated",
// per the local `StapleItem.isActive` doc comment) is carried over field-
// for-field for interface parity with iOS, but toggling it has NO
// downstream effect in this backend today: there is no group-scoped
// "regenerate suggestions from the meal plan + active staples" endpoint at
// all, and even locally, `GroceryListBuilder.regenerate` — the one place
// that *could* merge active staples into suggestions — is deliberately
// never called with real staples (`GroceryListView.generateSuggestions`
// always passes `[]`, so "a short/empty meal-plan result reads as 'nothing
// needed,' not as a wall of unrelated staples" per that file's own doc
// comment). Wiring staples into suggestion-generation here would make this
// backend do something the local app itself deliberately doesn't do —
// so this endpoint stores and returns `isActive` faithfully, and
// deliberately does nothing else with it, matching current local behavior
// exactly rather than getting ahead of it.
const UpdateStapleSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200).optional(),
    category: z.enum(GROCERY_CATEGORIES).optional(),
    defaultQuantityText: z.string().trim().max(200).nullable().optional(),
    isActive: z.boolean().optional(),
  })
  .strict();

router.patch("/:id", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const parsed = UpdateStapleSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const data = parsed.data;

  const existing = await prisma.groupStapleItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Staple not found." });
  }

  const updates = {};
  if (data.name !== undefined) updates.name = data.name;
  if (data.category !== undefined) updates.category = data.category;
  if (data.defaultQuantityText !== undefined) updates.defaultQuantityText = data.defaultQuantityText;
  if (data.isActive !== undefined) updates.isActive = data.isActive;

  const staple = await prisma.groupStapleItem.update({ where: { id: existing.id }, data: updates });
  res.json({ staple: serializeStaple(staple) });
}));

// DELETE /groups/:groupId/grocery/staples/:id — any member, same
// reasoning as the rest of this file.
router.delete("/:id", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const existing = await prisma.groupStapleItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Staple not found." });
  }

  await prisma.groupStapleItem.delete({ where: { id: existing.id } });
  res.status(204).end();
}));

module.exports = router;
