// GET /me and PATCH /me — the caller's own profile. Both require auth (see
// index.js, which applies requireAuth before mounting this router).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// Shared between GET and PATCH's response so the two never drift — every
// profile field a caller can see/set about themselves.
function selfProfile(user) {
  return {
    id: user.id,
    phoneNumber: user.phoneNumber,
    displayName: user.displayName,
    firstName: user.firstName,
    lastName: user.lastName,
    city: user.city,
    country: user.country,
    createdAt: user.createdAt,
  };
}

router.get("/", asyncHandler(async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!user) {
    // The JWT was valid but the user row is gone — shouldn't normally
    // happen (there's no delete-account flow yet), but fail clearly rather
    // than pretending the profile exists.
    return res.status(404).json({ error: "User not found." });
  }
  res.json({ user: selfProfile(user) });
}));

// Every field here is independently optional — a partial update, same
// "omitted key means leave it alone" semantics as recipe-library's PATCH
// (see routes/recipeLibrary.js) — but unlike that route, nothing here is
// ever meant to be explicitly clearable back to null (a phone number
// always has some plausible first/last name eventually; there's no "clear
// your city" use case worth the extra omit-vs-null plumbing that route
// needed for a recipe's optional summary), so a plain `.optional()` field
// per key is enough. `.refine` below just rejects a genuinely empty
// request rather than silently no-op'ing it.
const UpdateMeSchema = z
  .object({
    displayName: z.string().trim().min(1, "displayName can't be empty.").max(100).optional(),
    firstName: z.string().trim().min(1, "firstName can't be empty.").max(100).optional(),
    lastName: z.string().trim().min(1, "lastName can't be empty.").max(100).optional(),
    city: z.string().trim().min(1, "city can't be empty.").max(100).optional(),
    country: z.string().trim().min(1, "country can't be empty.").max(100).optional(),
  })
  .refine((data) => Object.keys(data).length > 0, {
    message: "Provide at least one field to update.",
  });

router.patch("/", asyncHandler(async (req, res) => {
  const parsed = UpdateMeSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }

  // `parsed.data` only contains the keys actually present in the request
  // body (zod's `.optional()` fields simply aren't present in the parsed
  // output when omitted, no `.default()` involved) — safe to spread
  // straight into Prisma's `data` as a genuine partial update.
  const user = await prisma.user.update({
    where: { id: req.userId },
    data: parsed.data,
  });
  res.json({ user: selfProfile(user) });
}));

module.exports = router;
