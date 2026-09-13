// A group's shared meal plan (Phase 3) — one plan per group, everyone in
// the group sees the same rows (contrast with recipe sharing, which is "my
// recipe, shared with specific people/groups"; this is "belongs to the
// group outright"). Mounted at /groups/:groupId/meal-plan in index.js,
// behind requireAuth like every other group route. Every route here also
// re-checks membership itself (never trusts the mount path alone) — same
// rigor as routes/groups.js and routes/recipeLibrary.js's own ownership
// checks.
//
// Roles: a MANAGER can decide a meal directly (POST) and adopt/remove a
// suggestion; any member can suggest something for a vote and vote on it;
// a suggestion can also be withdrawn by whoever proposed it, not just a
// MANAGER — see each route's own comment below for the specific rule and
// reasoning. See the GroupRole doc comment in prisma/schema.prisma for the
// permission model this implements ("Managers can add stuff to the meal
// plans etc, participants can suggest things to vote or suggest a recipe
// etc").
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router({ mergeParams: true });

// Duplicated rather than imported from routes/groups.js — same "small
// helper, kept local per file" convention routes/recipeLibrary.js already
// uses for its own copies of publicUser/isAcceptedFriend/membershipFor.
function membershipFor(groupId, userId) {
  return prisma.groupMembership.findUnique({
    where: { userId_groupId: { userId, groupId } },
  });
}

// Every route below needs "is the caller a member, and are they a
// MANAGER" — loaded once per request rather than re-derived per route.
// Attaches `req.groupMembership`; sends the 403 and returns null itself
// when the caller isn't a member, so route handlers can just check for
// null and return.
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

// Loads a Recipe and checks the caller can actually see it (owner, a
// direct share target, or a member of a group it's shared with) — the same
// three-way check routes/recipeLibrary.js's loadRecipeForViewer uses,
// duplicated here rather than imported (that function isn't exported, and
// this file's needs are narrower — existence + visibility, not the full
// serialized recipe). Required so planning/suggesting a meal can't be used
// to plant an arbitrary, otherwise-invisible recipeId into a group's shared
// plan — same "same rigor as existing ownership checks" standard the rest
// of this codebase holds to, even though the feature spec's own wording
// ("a recipe must already exist in the recipe-library") only strictly
// requires existence.
async function recipeVisibleToUser(recipeId, userId) {
  const recipe = await prisma.recipe.findUnique({ where: { id: recipeId } });
  if (!recipe) return false;
  if (recipe.ownerId === userId) return true;
  const directShare = await prisma.recipeShare.findFirst({
    where: { recipeId, sharedWithUserId: userId },
  });
  if (directShare) return true;
  const groupShare = await prisma.recipeShare.findFirst({
    where: {
      recipeId,
      sharedWithGroupId: { not: null },
      sharedWithGroup: { memberships: { some: { userId } } },
    },
  });
  return Boolean(groupShare);
}

function serializePlannedMeal(meal) {
  return {
    id: meal.id,
    groupId: meal.groupId,
    date: meal.date,
    slot: meal.slot,
    recipeId: meal.recipeId,
    restaurantName: meal.restaurantName,
    isOrderIn: meal.isOrderIn,
    decidedByUserId: meal.decidedByUserId,
    decidedAt: meal.decidedAt,
  };
}

function serializeSuggestion(suggestion, viewerUserId) {
  return {
    id: suggestion.id,
    groupId: suggestion.groupId,
    date: suggestion.date,
    slot: suggestion.slot,
    recipeId: suggestion.recipeId,
    restaurantName: suggestion.restaurantName,
    isOrderIn: suggestion.isOrderIn,
    proposedByUserId: suggestion.proposedByUserId,
    createdAt: suggestion.createdAt,
    voteCount: suggestion.votes.length,
    votedByMe: suggestion.votes.some((vote) => vote.userId === viewerUserId),
  };
}

// Shared by POST / (decide) and POST /suggestions (propose): the
// recipe-or-restaurant shape both rows have. Exactly one of recipeId/
// restaurantName must be set — Prisma/Postgres can't express that as a
// schema constraint (same situation as RecipeShare in
// prisma/schema.prisma), so it's checked explicitly below, same pattern as
// routes/recipeLibrary.js's ShareSchema/XOR check.
const MealShapeSchema = z
  .object({
    date: z.coerce.date(),
    slot: z.enum(["BREAKFAST", "LUNCH", "DINNER", "OTHER"]),
    recipeId: z.string().uuid().optional(),
    restaurantName: z.string().trim().min(1).max(200).optional(),
    isOrderIn: z.boolean().optional().default(false),
  })
  .strict();

async function parseMealShape(req, res) {
  const parsed = MealShapeSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
    return null;
  }
  const { recipeId, restaurantName } = parsed.data;
  if ((recipeId && restaurantName) || (!recipeId && !restaurantName)) {
    res.status(400).json({ error: "Provide exactly one of recipeId or restaurantName, not both or neither." });
    return null;
  }
  if (recipeId && !(await recipeVisibleToUser(recipeId, req.userId))) {
    res.status(400).json({ error: "That recipe doesn't exist or you don't have access to it." });
    return null;
  }
  return parsed.data;
}

// GET /groups/:groupId/meal-plan — everything for the group: every decided
// PlannedMeal and every pending MealSuggestion. No date-range filtering
// server-side (household-sized data) — the client filters by date locally,
// same as the existing local DaySlotsView/CalendarPlanView already do with
// their own @Query data.
router.get("/", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const [plannedMeals, suggestions] = await Promise.all([
    prisma.plannedMeal.findMany({
      where: { groupId: req.params.groupId },
      orderBy: { date: "asc" },
    }),
    prisma.mealSuggestion.findMany({
      where: { groupId: req.params.groupId },
      include: { votes: true },
      orderBy: { date: "asc" },
    }),
  ]);

  res.json({
    plannedMeals: plannedMeals.map(serializePlannedMeal),
    suggestions: suggestions.map((s) => serializeSuggestion(s, req.userId)),
  });
}));

// POST /groups/:groupId/meal-plan — MANAGER only. Directly decides a meal
// (created already-decided, not a suggestion) — the "Managers can add stuff
// to the meal plans" half of the feature's permission model.
// Body: { date, slot, recipeId } or { date, slot, restaurantName,
// isOrderIn? }.
router.post("/", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;
  if (!isManager(membership)) {
    return res.status(403).json({ error: "Only a group manager can add to the meal plan." });
  }

  const data = await parseMealShape(req, res);
  if (!data) return;

  const meal = await prisma.plannedMeal.create({
    data: {
      groupId: req.params.groupId,
      date: data.date,
      slot: data.slot,
      recipeId: data.recipeId ?? null,
      restaurantName: data.restaurantName ?? null,
      isOrderIn: data.recipeId ? false : data.isOrderIn,
      decidedByUserId: req.userId,
    },
  });

  res.status(201).json({ plannedMeal: serializePlannedMeal(meal) });
}));

// DELETE /groups/:groupId/meal-plan/:id — MANAGER only.
router.delete("/:id", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;
  if (!isManager(membership)) {
    return res.status(403).json({ error: "Only a group manager can remove a planned meal." });
  }

  const meal = await prisma.plannedMeal.findUnique({ where: { id: req.params.id } });
  if (!meal || meal.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Planned meal not found." });
  }
  await prisma.plannedMeal.delete({ where: { id: meal.id } });
  res.status(204).end();
}));

// POST /groups/:groupId/meal-plan/suggestions — any member. The
// Participant-facing "suggest a recipe/restaurant/order-in for a vote"
// action. The proposer is counted as having voted for their own suggestion
// by default (mirrors the iOS MealSuggestion model's
// `votedMemberIDs: [proposedByMemberID]` default — see
// HomeEats/Models/MealSuggestion.swift).
router.post("/suggestions", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const data = await parseMealShape(req, res);
  if (!data) return;

  const suggestion = await prisma.mealSuggestion.create({
    data: {
      groupId: req.params.groupId,
      date: data.date,
      slot: data.slot,
      recipeId: data.recipeId ?? null,
      restaurantName: data.restaurantName ?? null,
      isOrderIn: data.recipeId ? false : data.isOrderIn,
      proposedByUserId: req.userId,
      votes: { create: [{ userId: req.userId }] },
    },
    include: { votes: true },
  });

  res.status(201).json({ suggestion: serializeSuggestion(suggestion, req.userId) });
}));

// POST /groups/:groupId/meal-plan/suggestions/:id/vote — any member,
// toggles the caller's own vote on/off. `@@unique([suggestionId, userId])`
// on MealSuggestionVote is what makes this a clean insert-or-delete rather
// than needing to read-then-decide inside a transaction.
router.post("/suggestions/:id/vote", asyncHandler(async (req, res) => {
  if (!(await requireMembership(req, res))) return;

  const suggestion = await prisma.mealSuggestion.findUnique({ where: { id: req.params.id } });
  if (!suggestion || suggestion.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Suggestion not found." });
  }

  const existingVote = await prisma.mealSuggestionVote.findUnique({
    where: { suggestionId_userId: { suggestionId: suggestion.id, userId: req.userId } },
  });

  if (existingVote) {
    await prisma.mealSuggestionVote.delete({ where: { id: existingVote.id } });
  } else {
    await prisma.mealSuggestionVote.create({
      data: { suggestionId: suggestion.id, userId: req.userId },
    });
  }

  const updated = await prisma.mealSuggestion.findUnique({
    where: { id: suggestion.id },
    include: { votes: true },
  });
  res.json({ suggestion: serializeSuggestion(updated, req.userId) });
}));

// POST /groups/:groupId/meal-plan/suggestions/:id/adopt — MANAGER only.
// Converts the suggestion into a decided PlannedMeal (same date/slot/
// recipe-or-restaurant) and deletes the suggestion (and its votes, via
// cascade), inside one transaction so this never leaves both a PlannedMeal
// and the now-redundant MealSuggestion behind if something fails partway.
router.post("/suggestions/:id/adopt", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;
  if (!isManager(membership)) {
    return res.status(403).json({ error: "Only a group manager can adopt a suggestion." });
  }

  const suggestion = await prisma.mealSuggestion.findUnique({ where: { id: req.params.id } });
  if (!suggestion || suggestion.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Suggestion not found." });
  }

  const plannedMeal = await prisma.$transaction(async (tx) => {
    const created = await tx.plannedMeal.create({
      data: {
        groupId: suggestion.groupId,
        date: suggestion.date,
        slot: suggestion.slot,
        recipeId: suggestion.recipeId,
        restaurantName: suggestion.restaurantName,
        isOrderIn: suggestion.isOrderIn,
        decidedByUserId: req.userId,
      },
    });
    await tx.mealSuggestion.delete({ where: { id: suggestion.id } });
    return created;
  });

  res.status(201).json({ plannedMeal: serializePlannedMeal(plannedMeal) });
}));

// DELETE /groups/:groupId/meal-plan/suggestions/:id — MANAGER, or the
// original proposer of that specific suggestion (mirrors the existing
// local-app pattern where you can withdraw your own suggestion if you
// change your mind — see GroceryListView's equivalent reject/withdraw
// reasoning). Anyone else, including a fellow PARTICIPANT who didn't
// propose it, gets a 403.
router.delete("/suggestions/:id", asyncHandler(async (req, res) => {
  const membership = await requireMembership(req, res);
  if (!membership) return;

  const suggestion = await prisma.mealSuggestion.findUnique({ where: { id: req.params.id } });
  if (!suggestion || suggestion.groupId !== req.params.groupId) {
    return res.status(404).json({ error: "Suggestion not found." });
  }
  if (!isManager(membership) && suggestion.proposedByUserId !== req.userId) {
    return res.status(403).json({ error: "Only a group manager or the original proposer can remove this suggestion." });
  }

  await prisma.mealSuggestion.delete({ where: { id: suggestion.id } });
  res.status(204).end();
}));

module.exports = router;
