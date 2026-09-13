// A group's shared grocery list (Phase 3) — one list per group, same
// "belongs to the group outright" relationship as the meal plan in
// routes/groupMealPlan.js. Mounted at /groups/:groupId/grocery in
// index.js, behind requireAuth; every route here re-checks membership
// itself (never trusts the mount path alone), same rigor as the rest of
// this codebase's group routes.
//
// v1 deliberately has no group-scoped "My Layout" custom-aisle subsystem —
// see the GroupGroceryItem doc comment in prisma/schema.prisma — group
// lists only support category-grouped ordering (`orderIndex`), matching
// the iOS "By Category" view mode.
//
// Roles here are more fine-grained than the meal plan's route-level
// MANAGER/PARTICIPANT split — see each route's own comment below for the
// specific, sometimes field-level, reasoning (POST's section restriction,
// PATCH's field-by-field split, DELETE's section-dependent rule).
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
    isChecked: item.isChecked,
    orderIndex: item.orderIndex,
    addedByUserId: item.addedByUserId,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  };
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

const CreateItemSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200),
    category: z.enum(GROCERY_CATEGORIES),
    section: z.enum(GROCERY_SECTIONS),
    quantityText: z.string().trim().max(200).optional().default(""),
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
// - `isChecked`/`orderIndex`: any member may change these. Checking an item
//   off (shopping) or reordering it (tidying the list) is routine
//   day-to-day use of an already-decided list, not a planning decision —
//   the same reasoning the meal plan gives PARTICIPANTs a vote/suggest but
//   not a decide action doesn't apply here, since nothing about *using* the
//   list changes what's actually on it.
// - `name`/`category`/`quantityText`/`section`: MANAGER only. These change
//   what's actually on the list or how it's organized/categorized — more
//   like editing the plan itself (the same category POST's section rule
//   already gates who can add straight onto the real list) — so they get
//   the same MANAGER-only treatment as adding an item directly.
//
// A PARTICIPANT's request touching only isChecked/orderIndex succeeds; one
// that ALSO includes any of the MANAGER-only fields is rejected outright
// (400) rather than silently applying the allowed subset and dropping the
// rest — so a client always gets an explicit signal instead of a
// partially-applied update it might not notice.
const UpdateItemSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200).optional(),
    category: z.enum(GROCERY_CATEGORIES).optional(),
    quantityText: z.string().trim().max(200).optional(),
    section: z.enum(GROCERY_SECTIONS).optional(),
    isChecked: z.boolean().optional(),
    orderIndex: z.number().finite().optional(),
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
        error: `Only a group manager can change ${touchedManagerOnlyField}. Members can update isChecked and orderIndex.`,
      });
    }
  }

  const existing = await prisma.groupGroceryItem.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Grocery item not found." });
  }

  const updates = {};
  if (data.name !== undefined) updates.name = data.name;
  if (data.category !== undefined) updates.category = data.category;
  if (data.quantityText !== undefined) updates.quantityText = data.quantityText;
  if (data.section !== undefined) updates.section = data.section;
  if (data.isChecked !== undefined) updates.isChecked = data.isChecked;
  if (data.orderIndex !== undefined) updates.orderIndex = data.orderIndex;

  const item = await prisma.groupGroceryItem.update({ where: { id: existing.id }, data: updates });
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
