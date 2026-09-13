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

// 100 is a generous ceiling for a household/friend-group app (a big
// extended-family or friend-group circle, not a company directory) while
// still bounding the sequential per-id `isAcceptedFriend` check loop below
// to something that can't be abused as a cheap way to make one request
// trigger an unbounded number of DB queries.
const MAX_GROUP_MEMBER_IDS = 100;

const CreateGroupSchema = z.object({
  name: z.string().trim().min(1, "name can't be empty.").max(200),
  memberUserIds: z
    .array(z.string().uuid())
    .max(MAX_GROUP_MEMBER_IDS, `memberUserIds can't have more than ${MAX_GROUP_MEMBER_IDS} entries.`)
    .optional()
    .default([]),
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
// already a Home Eats user, a user who isn't yet a friend, or not a user at
// all). Only an existing member may invite.
//
// `userId` must be one of the caller's accepted friends — same restriction
// as group creation — and, if so, is added as a member directly. Since the
// caller supplied this id themselves (e.g. from their own friends list),
// there's no new information for a 400 here to leak.
//
// `phoneNumber` is different: if it happens to match one of the caller's
// *own* accepted friends, they're added directly, same as the `userId`
// path (again no leak — the caller already knows their own friend's phone
// number). Anything else a `phoneNumber` could resolve to — a user who
// isn't yet an accepted friend, or no user at all — queues the exact same
// kind of standing Invite with this `groupId`, and reports back with the
// exact same response shape/status either way. Treating "real user, not
// yet a friend" and "not a user at all" identically (instead of the former
// 400ing with "must be an accepted friend") is deliberate: a caller could
// otherwise send phone numbers here purely to learn which ones belong to
// registered Home Eats users, with no actual relationship to the caller
// required — see backend/README.md's note on this. The Invite queued
// either way resolves into real GroupMembership only once the caller and
// that phone number's eventual account become mutual, ACCEPTED friends
// with the caller as the friendship's requester (see
// `resolveInvitesForAcceptedFriendship` in routes/friends.js) — i.e. it's
// exactly as if the caller had also sent that person a friend request, they
// just have to actually accept it before anything is granted.
const InviteSchema = z.union([
  z.object({ userId: z.string().uuid() }),
  z.object({ phoneNumber: phoneNumberField }),
]);

// The one success shape for "I sent something to this phone number" (the
// `phoneNumber`-and-not-an-accepted-friend branch below) — see the route's
// own doc comment above for why this must be identical whether the number
// belongs to a not-yet-friend user or no user at all.
function invitedResponse(res) {
  return res.status(201).json({ status: "invited" });
}

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

  if ("userId" in parsed.data) {
    const targetUserId = parsed.data.userId;
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

  const phoneNumber = parsed.data.phoneNumber;
  const existingUser = await prisma.user.findUnique({ where: { phoneNumber } });

  if (existingUser && (await isAcceptedFriend(req.userId, existingUser.id))) {
    const existingMembership = await membershipFor(req.params.groupId, existingUser.id);
    if (existingMembership) {
      return res.status(409).json({ error: "That person is already a member of this group." });
    }
    const newMembership = await prisma.groupMembership.create({
      data: { userId: existingUser.id, groupId: req.params.groupId },
      include: { user: true },
    });
    return res.status(201).json({ member: publicUser(newMembership.user) });
  }

  // Either not a Home Eats user yet, or one who isn't yet an accepted
  // friend of the caller — both queue the same standing Invite (see the
  // route's own doc comment above for why these two must not be
  // distinguishable from the response).
  const existingInvite = await prisma.invite.findFirst({
    where: { invitedPhoneNumber: phoneNumber, groupId: req.params.groupId, status: "PENDING" },
  });
  if (existingInvite) {
    return res.status(409).json({ error: "That phone number has already been invited to this group." });
  }

  await prisma.$transaction(async (tx) => {
    await tx.invite.create({
      data: { invitingUserId: req.userId, invitedPhoneNumber: phoneNumber, groupId: req.params.groupId },
    });

    // The Invite above only ever turns into GroupMembership once there's a
    // Friendship between the caller and that phone number's account, ACCEPTED
    // with the caller as its requester (see
    // `resolveInvitesForAcceptedFriendship` in routes/friends.js) — so if
    // that phone number already belongs to a user and there's no Friendship
    // row between them at all yet, send that ordinary friend request right
    // now, same as routes/friends.js's own POST /request would. An existing
    // Friendship in some other state (already PENDING either direction, or
    // DECLINED) is deliberately left untouched — this only ever creates a
    // *fresh* request; the queued Invite still stands either way, it just
    // won't auto-resolve into membership unless/until that separate
    // friend-request situation is itself resolved with the caller ending up
    // as the accepted friendship's requester.
    if (existingUser) {
      const existingFriendship = await tx.friendship.findFirst({
        where: {
          OR: [
            { requesterId: req.userId, recipientId: existingUser.id },
            { requesterId: existingUser.id, recipientId: req.userId },
          ],
        },
      });
      if (!existingFriendship) {
        await tx.friendship.create({
          data: { requesterId: req.userId, recipientId: existingUser.id, status: "PENDING" },
        });
      }
    }
  });

  return invitedResponse(res);
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
