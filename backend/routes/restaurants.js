// Personal restaurant library — the backend counterpart of the iOS
// `Restaurant` SwiftData model. Mounted at `/restaurants/library`
// (deliberately NOT `/restaurants`, which is already the unauthenticated
// Google-Places-proxy search API registered directly on `app` in
// index.js — this is a distinct, auth-required CRUD API for a signed-in
// user's own saved restaurants, same "own distinct prefix, never confused
// with an existing route" reasoning as `/recipe-library` gives for staying
// out of `/recipes/*`). Every route here requires auth (mounted behind
// requireAuth in index.js), same as recipe-library/friends/groups.
//
// No sharing/visibility concept at all, unlike recipe-library — every
// restaurant here is simply "the caller's own." Added so a user's
// restaurant library survives a local-store reset and is recoverable
// across devices/reinstalls, the direct fix for a real incident where a
// missing SwiftData migration default wiped a user's entire local store —
// see prisma/schema.prisma's own doc comment on the Restaurant model, and
// HomeEatsApp.swift's doc comment on ModelContainer creation, for the full
// story.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// Shape returned for a Restaurant everywhere below — field-for-field the
// same names `RemoteRestaurant` (iOS) expects, same "no reshaping needed at
// the API boundary" convention `serializeRecipe`/`serializeItem` already
// follow elsewhere in this backend.
function serializeRestaurant(restaurant) {
  return {
    id: restaurant.id,
    ownerId: restaurant.ownerId,
    name: restaurant.name,
    cuisine: restaurant.cuisine,
    priceRange: restaurant.priceRange,
    rating: restaurant.rating,
    notes: restaurant.notes,
    websiteUrl: restaurant.websiteUrl,
    address: restaurant.address,
    isFavorite: restaurant.isFavorite,
    googlePhotoNames: restaurant.googlePhotoNames,
    googlePlaceId: restaurant.googlePlaceId,
    latitude: restaurant.latitude,
    longitude: restaurant.longitude,
    createdAt: restaurant.createdAt,
    updatedAt: restaurant.updatedAt,
  };
}

// Every field optional at the schema level except `name` — every one of
// these mirrors an optional field on the iOS `Restaurant` model, so a
// restaurant added manually (no Google source at all) legitimately has
// most of these `null`/absent from the very start, not just after editing.
const RestaurantFieldsSchema = {
  name: z.string().trim().min(1, "name can't be empty.").max(200),
  cuisine: z.string().trim().max(200).nullable().optional(),
  priceRange: z.string().trim().max(20).nullable().optional(),
  rating: z.number().int().min(1).max(5).nullable().optional(),
  notes: z.string().trim().max(5000).nullable().optional(),
  websiteUrl: z.string().trim().max(2000).nullable().optional(),
  address: z.string().trim().max(500).nullable().optional(),
  isFavorite: z.boolean().optional(),
  googlePhotoNames: z.array(z.string()).optional(),
  googlePlaceId: z.string().trim().max(500).nullable().optional(),
  latitude: z.number().finite().nullable().optional(),
  longitude: z.number().finite().nullable().optional(),
};

const CreateRestaurantSchema = z.object(RestaurantFieldsSchema).strict();
// Same shape, but every field (including `name`) optional — a PATCH only
// ever sends what actually changed, same partial-update convention as
// `PATCH /me` and `PATCH /recipe-library/:recipeId`.
const UpdateRestaurantSchema = z
  .object({ ...RestaurantFieldsSchema, name: RestaurantFieldsSchema.name.optional() })
  .strict();

// GET /restaurants/library — every restaurant the caller owns. No
// pagination (matches `GET /recipe-library/mine`'s own "a household's
// library is small enough to just send it all" call).
router.get("/", asyncHandler(async (req, res) => {
  const restaurants = await prisma.restaurant.findMany({
    where: { ownerId: req.userId },
    orderBy: { createdAt: "asc" },
  });
  res.json({ restaurants: restaurants.map(serializeRestaurant) });
}));

router.post("/", asyncHandler(async (req, res) => {
  const parsed = CreateRestaurantSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const restaurant = await prisma.restaurant.create({
    data: { ...parsed.data, ownerId: req.userId },
  });
  res.status(201).json({ restaurant: serializeRestaurant(restaurant) });
}));

router.patch("/:id", asyncHandler(async (req, res) => {
  const parsed = UpdateRestaurantSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const existing = await prisma.restaurant.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.ownerId !== req.userId) {
    return res.status(404).json({ error: "Restaurant not found." });
  }
  const restaurant = await prisma.restaurant.update({
    where: { id: existing.id },
    data: parsed.data,
  });
  res.json({ restaurant: serializeRestaurant(restaurant) });
}));

router.delete("/:id", asyncHandler(async (req, res) => {
  const existing = await prisma.restaurant.findUnique({ where: { id: req.params.id } });
  if (!existing || existing.ownerId !== req.userId) {
    return res.status(404).json({ error: "Restaurant not found." });
  }
  await prisma.restaurant.delete({ where: { id: existing.id } });
  res.status(204).end();
}));

module.exports = router;
