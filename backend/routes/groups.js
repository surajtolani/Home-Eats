// Groups — the "household", but also generically any shared circle (e.g.
// "our Peru trip"): built from a user's friends list, and a user can belong
// to many groups at once. Nothing here (or in prisma/schema.prisma's
// GroupMembership model) assumes a user has only one group. Every route
// requires auth (mounted behind requireAuth in index.js).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { phoneNumberField } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// Same "safe to share with someone who has a legitimate relationship"
// shape as routes/friends.js's publicUser — here that relationship is
// "fellow member of this same group", checked by the caller before this is
// ever used.
function publicUser(user) {
  return { id: user.id, displayName: user.displayName, phoneNumber: user.phoneNumber };
}

async function isAcceptedFriend(userIdA, userIdB) {
  const friendship = await prisma.friendship.findFirst({
    where: {
      status: "ACCEPTED",
      OR: [
        { requesterId: userIdA, recipientId: userIdB },
        { requesterId: userIdB, recipientId: userIdA },
      ],
    },
  });
  return Boolean(friendship);
}

function membershipFor(groupId, userId) {
  return prisma.groupMembership.findUnique({
    where: { userId_groupId: { userId, groupId } },
  });
}

const CreateGroupSchema = z.object({
  name: z.string().trim().min(1, "name can't be empty.").max(200),
  memberUserIds: z.array(z.string().uuid()).optional().default([]),
});

// POST /groups
// Body: { name, memberUserIds?: string[] } — creates a group, makes the
// caller a member, and adds any given memberUserIds. Every id in
// memberUserIds must be one of the caller's existing accepted friends —
// this is what stops someone from adding an arbitrary stranger's userId
// straight into a group they share nothing with.
router.post("/", asyncHandler(async (req, res) => {
  const parsed = CreateGroupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const { name, memberUserIds } = parsed.data;
  const otherMemberIds = [...new Set(memberUserIds)].filter((id) => id !== req.userId);

  for (const memberId of otherMemberIds) {
    // Sequential on purpose — these are validation checks that should fail
    // fast on the first bad id, and the list is small (a group invite list,
    // not a bulk import).
    // eslint-disable-next-line no-await-in-loop
    const friends = await isAcceptedFriend(req.userId, memberId);
    if (!friends) {
      return res.status(400).json({ error: `${memberId} is not one of your accepted friends.` });
    }
  }

  const group = await prisma.group.create({
    data: {
      name,
      createdByUserId: req.userId,
      memberships: {
        create: [req.userId, ...otherMemberIds].map((userId) => ({ userId })),
      },
    },
    include: { memberships: { include: { user: true } } },
  });

  res.status(201).json({
    group: {
      id: group.id,
      name: group.name,
      createdByUserId: group.createdByUserId,
      createdAt: group.createdAt,
      members: group.memberships.map((m) => publicUser(m.user)),
    },
  });
}));

// GET /groups — every group the caller belongs to (no member list here —
// use GET /groups/:groupId for that — this is meant as a lightweight
// "which groups am I in" list).
router.get("/", asyncHandler(async (req, res) => {
  const memberships = await prisma.groupMembership.findMany({
    where: { userId: req.userId },
    include: { group: true },
  });
  res.json({
    groups: memberships.map((m) => ({
      id: m.group.id,
      name: m.group.name,
      createdByUserId: m.group.createdByUserId,
      createdAt: m.group.createdAt,
    })),
  });
}));

// GET /groups/:groupId — group details + member list. Phone numbers are
// included here since every person in the response is, by definition, a
// fellow member of this same group; a caller who isn't a member gets a 403
// before any of that data is ever read.
router.get("/:groupId", asyncHandler(async (req, res) => {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }

  const group = await prisma.group.findUnique({
    where: { id: req.params.groupId },
    include: { memberships: { include: { user: true } } },
  });
  if (!group) {
    return res.status(404).json({ error: "Group not found." });
  }

  res.json({
    group: {
      id: group.id,
      name: group.name,
      createdByUserId: group.createdByUserId,
      createdAt: group.createdAt,
      members: group.memberships.map((m) => publicUser(m.user)),
    },
  });
}));

// POST /groups/:groupId/invite
// Body: { userId } (an existing friend) or { phoneNumber } (anyone else —
// already a Home Eats user or not). Only an existing member may invite.
// A `userId` invite, and a `phoneNumber` invite that turns out to already
// belong to a user, must both be one of the caller's accepted friends —
// same restriction as group creation, so this can't be used as a second
// way to add an arbitrary stranger. A `phoneNumber` that isn't a user yet
// creates an Invite with this groupId, auto-resolved into membership on
// signup (see POST /auth/verify-code).
const InviteSchema = z.union([
  z.object({ userId: z.string().uuid() }),
  z.object({ phoneNumber: phoneNumberField }),
]);

router.post("/:groupId/invite", asyncHandler(async (req, res) => {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  const group = await prisma.group.findUnique({ where: { id: req.params.groupId } });
  if (!group) {
    return res.status(404).json({ error: "Group not found." });
  }

  const parsed = InviteSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Provide either userId or phoneNumber." });
  }

  // Resolve to a target userId either directly (userId given) or by
  // looking up an existing user with that phone number — both paths share
  // the same "must be an accepted friend, must not already be a member"
  // checks below.
  let targetUserId = null;
  if ("userId" in parsed.data) {
    targetUserId = parsed.data.userId;
  } else {
    const existingUser = await prisma.user.findUnique({ where: { phoneNumber: parsed.data.phoneNumber } });
    if (existingUser) targetUserId = existingUser.id;
  }

  if (targetUserId) {
    if (!(await isAcceptedFriend(req.userId, targetUserId))) {
      return res.status(400).json({ error: "You can only add your accepted friends to a group." });
    }
    const existingMembership = await membershipFor(req.params.groupId, targetUserId);
    if (existingMembership) {
      return res.status(409).json({ error: "That person is already a member of this group." });
    }
    const newMembership = await prisma.groupMembership.create({
      data: { userId: targetUserId, groupId: req.params.groupId },
      include: { user: true },
    });
    return res.status(201).json({ member: publicUser(newMembership.user) });
  }

  // Not yet a user — queue an Invite that auto-resolves into membership
  // (and a friendship with the inviter) on signup.
  const phoneNumber = parsed.data.phoneNumber;
  const existingInvite = await prisma.invite.findFirst({
    where: { invitedPhoneNumber: phoneNumber, groupId: req.params.groupId, status: "PENDING" },
  });
  if (existingInvite) {
    return res.status(409).json({ error: "That phone number has already been invited to this group." });
  }
  const invite = await prisma.invite.create({
    data: { invitingUserId: req.userId, invitedPhoneNumber: phoneNumber, groupId: req.params.groupId },
  });
  res.status(201).json({ invite });
}));

// DELETE /groups/:groupId/members/:userId — leave (self) or remove (any
// current member can remove any other member). No admin-role system in
// v1 — every member has equal standing to remove anyone, including the
// group's creator; a caller who isn't a member themselves gets a 403.
router.delete("/:groupId/members/:userId", asyncHandler(async (req, res) => {
  const callerMembership = await membershipFor(req.params.groupId, req.userId);
  if (!callerMembership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  const targetMembership = await membershipFor(req.params.groupId, req.params.userId);
  if (!targetMembership) {
    return res.status(404).json({ error: "That user is not a member of this group." });
  }
  await prisma.groupMembership.delete({ where: { id: targetMembership.id } });
  res.status(204).end();
}));

module.exports = router;
