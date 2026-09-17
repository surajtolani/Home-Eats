// Personal meal history — the backend counterpart of the iOS
// `MealHistoryEntry` SwiftData model. Mounted at `/meal-history`, its own
// distinct prefix same as `/recipe-library`/`/restaurants/library`. Every
// route here requires auth (mounted behind requireAuth in index.js).
//
// Same "purely mine, no sharing/visibility concept" shape as
// routes/restaurants.js, and this file deliberately mirrors that one
// closely — see MealHistoryEntry's own doc comment in prisma/schema.prisma
// for why this table exists (account-backed durability + multi-device sync,
// same reasoning as Recipe/Restaurant) and what it deliberately leaves out
// (`madeByMemberID`, a purely local `FamilyMember` reference with nothing
// to sync it to).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// Field-for-field the same names `RemoteMealHistoryEntry` (iOS) expects,
// same convention `serializeRestaurant`/`serializeRecipe` already follow.
function serializeEntry(entry) {
  return {
    id: entry.id,
    ownerId: entry.ownerId,
    date: entry.date,
    recipeId: entry.recipeId,
    restaurantId: entry.restaurantId,
    rating: entry.rating,
    notes: entry.notes,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
  };
}

const EntryFieldsSchema = {
  date: z.coerce.date(),
  recipeId: z.string().trim().min(1).nullable().optional(),
  restaurantId: z.string().trim().min(1).nullable().optional(),
  rating: z.enum(["DISLIKED", "NEUTRAL", "LIKED"]).nullable().optional(),
  notes: z.string().trim().max(5000).nullable().optional(),
};

const CreateEntrySchema = z.object(EntryFieldsSchema).strict();
// Same "only what actually changed" partial-update convention as
// UpdateRestaurantSchema — `date` is still required on create but optional
// to change afterward.
const UpdateEntrySchema = z
  .object({ ...EntryFieldsSchema, date: EntryFieldsSchema.date.optional() })
  .strict();

// GET /meal-history/mine — every entry the caller owns. No pagination,
// same "small enough to just send it all" call as
// GET /recipe-library/mine / GET /restaurants/library.
router.get("/mine", asyncHandler(async (req, res) => {
  const entries = await prisma.mealHistoryEntry.findMany({
    where: { ownerId: req.userId },
    orderBy: { date: "desc" },
  });
  res.json({ entries: entries.map(serializeEntry) });
}));

router.post("/", asyncHandler(async (req, res) => {
  const parsed = CreateEntrySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const entry = await prisma.mealHistoryEntry.create({
    data: { ...parsed.data, ownerId: req.userId },
  });
  res.status(201).json({ entry: serializeEntry(entry) });
}));

router.patch("/:id", asyncHandler(async (req, res) => {
  const parsed = UpdateEntrySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const existing = await prisma.mealHistoryEntry.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.ownerId !== req.userId) {
    return res.status(404).json({ error: "Meal history entry not found." });
  }
  const entry = await prisma.mealHistoryEntry.update({
    where: { id: existing.id },
    data: parsed.data,
  });
  res.json({ entry: serializeEntry(entry) });
}));

router.delete("/:id", asyncHandler(async (req, res) => {
  const existing = await prisma.mealHistoryEntry.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.ownerId !== req.userId) {
    return res.status(404).json({ error: "Meal history entry not found." });
  }
  await prisma.mealHistoryEntry.delete({ where: { id: existing.id } });
  res.status(204).end();
}));

module.exports = router;
