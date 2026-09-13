// GET /me and PATCH /me — the caller's own profile. Both require auth (see
// index.js, which applies requireAuth before mounting this router).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

router.get("/", asyncHandler(async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!user) {
    // The JWT was valid but the user row is gone — shouldn't normally
    // happen (there's no delete-account flow yet), but fail clearly rather
    // than pretending the profile exists.
    return res.status(404).json({ error: "User not found." });
  }
  res.json({
    user: {
      id: user.id,
      phoneNumber: user.phoneNumber,
      displayName: user.displayName,
      createdAt: user.createdAt,
    },
  });
}));

const UpdateMeSchema = z.object({
  displayName: z.string().trim().min(1, "displayName can't be empty.").max(100),
});

router.patch("/", asyncHandler(async (req, res) => {
  const parsed = UpdateMeSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid displayName." });
  }

  const user = await prisma.user.update({
    where: { id: req.userId },
    data: { displayName: parsed.data.displayName },
  });
  res.json({
    user: { id: user.id, phoneNumber: user.phoneNumber, displayName: user.displayName },
  });
}));

module.exports = router;
