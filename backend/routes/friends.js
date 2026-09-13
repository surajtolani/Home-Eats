// Personal friends list — the base layer groups are built from (see
// routes/groups.js: adding someone to a group requires them to already be
// an accepted friend). Modeled after Splitwise: a friend request is a
// directional Friendship row that becomes mutual once accepted; every route
// here requires auth (mounted behind requireAuth in index.js).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { phoneNumberField, PHONE_ERROR } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// The subset of a User row that's safe to hand back to someone who has a
// legitimate relationship with them (an accepted friend, an incoming/
// outgoing request to/from them, or — see routes/groups.js — a fellow
// member of a shared group). Never used for an arbitrary/unrelated userId.
function publicUser(user) {
  return { id: user.id, displayName: user.displayName, phoneNumber: user.phoneNumber };
}

const RequestFriendSchema = z.object({ phoneNumber: phoneNumberField });

// POST /friends/request
// Body: { phoneNumber } — the phone number of the person to friend, whether
// or not they're already a Home Eats user.
//
// - If they ARE a user: creates a PENDING Friendship from caller -> them,
//   unless a Friendship row already exists between the pair in either
//   direction (Friendship.@@unique only guards the exact same direction at
//   the database level, so the branches below check both directions and
//   reuse/flip the existing row rather than ever risking a second one).
// - If they are NOT yet a user: creates an Invite instead, which
//   auto-resolves into an ACCEPTED friendship the moment that phone number
//   verifies (see POST /auth/verify-code in routes/auth.js).
router.post("/request", asyncHandler(async (req, res) => {
  const parsed = RequestFriendSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || PHONE_ERROR });
  }
  const { phoneNumber } = parsed.data;

  const me = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!me) {
    return res.status(404).json({ error: "User not found." });
  }
  if (me.phoneNumber === phoneNumber) {
    return res.status(400).json({ error: "You can't friend yourself." });
  }

  const target = await prisma.user.findUnique({ where: { phoneNumber } });

  if (!target) {
    const existingInvite = await prisma.invite.findFirst({
      where: {
        invitingUserId: req.userId,
        invitedPhoneNumber: phoneNumber,
        groupId: null,
        status: "PENDING",
      },
    });
    if (existingInvite) {
      return res.status(409).json({ error: "You've already invited this phone number." });
    }
    const invite = await prisma.invite.create({
      data: { invitingUserId: req.userId, invitedPhoneNumber: phoneNumber },
    });
    return res.status(201).json({ invite });
  }

  const existing = await prisma.friendship.findFirst({
    where: {
      OR: [
        { requesterId: req.userId, recipientId: target.id },
        { requesterId: target.id, recipientId: req.userId },
      ],
    },
  });

  if (!existing) {
    const friendship = await prisma.friendship.create({
      data: { requesterId: req.userId, recipientId: target.id, status: "PENDING" },
    });
    return res.status(201).json({ friendship });
  }

  if (existing.status === "ACCEPTED") {
    return res.status(409).json({ error: "You're already friends." });
  }
  if (existing.status === "PENDING" && existing.requesterId === req.userId) {
    return res.status(409).json({ error: "Friend request already pending." });
  }
  if (existing.status === "PENDING" && existing.requesterId === target.id) {
    // They'd already requested us — treat our request as accepting theirs
    // instead of leaving two one-directional requests pointed at each other.
    const updated = await prisma.friendship.update({
      where: { id: existing.id },
      data: { status: "ACCEPTED" },
    });
    return res.json({ friendship: updated, autoAccepted: true });
  }
  // DECLINED — allow trying again, as a fresh request from us. Reuses the
  // row (updating its direction) rather than inserting a second one.
  const updated = await prisma.friendship.update({
    where: { id: existing.id },
    data: { requesterId: req.userId, recipientId: target.id, status: "PENDING" },
  });
  res.status(201).json({ friendship: updated });
}));

// Shared by accept/decline: loads the friendship, checks the caller is the
// recipient and it's still PENDING, and sends the appropriate error
// response (returning null) when it isn't.
async function loadPendingAsRecipient(req, res) {
  const friendship = await prisma.friendship.findUnique({ where: { id: req.params.friendshipId } });
  if (!friendship) {
    res.status(404).json({ error: "Friend request not found." });
    return null;
  }
  if (friendship.recipientId !== req.userId) {
    res.status(403).json({ error: "Only the recipient can respond to this request." });
    return null;
  }
  if (friendship.status !== "PENDING") {
    res.status(409).json({ error: `Request is already ${friendship.status.toLowerCase()}.` });
    return null;
  }
  return friendship;
}

// POST /friends/:friendshipId/accept — only the recipient may accept.
router.post("/:friendshipId/accept", asyncHandler(async (req, res) => {
  const friendship = await loadPendingAsRecipient(req, res);
  if (!friendship) return;
  const updated = await prisma.friendship.update({
    where: { id: friendship.id },
    data: { status: "ACCEPTED" },
  });
  res.json({ friendship: updated });
}));

// POST /friends/:friendshipId/decline — only the recipient may decline.
router.post("/:friendshipId/decline", asyncHandler(async (req, res) => {
  const friendship = await loadPendingAsRecipient(req, res);
  if (!friendship) return;
  const updated = await prisma.friendship.update({
    where: { id: friendship.id },
    data: { status: "DECLINED" },
  });
  res.json({ friendship: updated });
}));

// GET /friends — accepted friends, plus separate pending incoming/outgoing
// request lists (mirrors Splitwise's contacts screen: "people you're
// friends with" is distinct from "requests waiting on you" and "requests
// you're waiting on").
router.get("/", asyncHandler(async (req, res) => {
  const rows = await prisma.friendship.findMany({
    where: { OR: [{ requesterId: req.userId }, { recipientId: req.userId }] },
    include: { requester: true, recipient: true },
  });

  const friends = [];
  const incomingRequests = [];
  const outgoingRequests = [];

  for (const row of rows) {
    const other = row.requesterId === req.userId ? row.recipient : row.requester;
    if (row.status === "ACCEPTED") {
      friends.push(publicUser(other));
    } else if (row.status === "PENDING" && row.recipientId === req.userId) {
      incomingRequests.push({ friendshipId: row.id, from: publicUser(other) });
    } else if (row.status === "PENDING" && row.requesterId === req.userId) {
      outgoingRequests.push({ friendshipId: row.id, to: publicUser(other) });
    }
    // DECLINED rows are omitted entirely — they're not surfaced back to
    // either side as a list item (routes/friends.js's POST /request still
    // lets the original requester try again, per the branch above).
  }

  res.json({ friends, incomingRequests, outgoingRequests });
}));

module.exports = router;
