// Personal friends list — the base layer groups are built from (see
// routes/groups.js: adding someone to a group requires them to already be
// an accepted friend). Modeled after Splitwise: a friend request is a
// directional Friendship row that becomes mutual once accepted; every route
// here requires auth (mounted behind requireAuth in index.js).
"use strict";

const express = require("express");
const { z } = require("zod");
const { Prisma } = require("@prisma/client");
const { prisma } = require("../lib/prisma");
const { phoneNumberField, PHONE_ERROR } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// POST /request's own existing-friendship check + insert aren't atomic
// under the default READ COMMITTED isolation — two near-simultaneous,
// opposite-direction requests could both read "no existing Friendship" and
// both insert a PENDING row (the `@@unique([requesterId, recipientId])`
// constraint only guards the exact same direction, not the reverse one —
// see the Friendship model's doc comment in prisma/schema.prisma), leaving
// two one-directional PENDING rows instead of the usual
// one-gets-auto-accepted outcome. Running the whole read-then-write as one
// `Serializable` transaction closes that: Postgres itself detects the
// conflict and fails one side with a serialization error (Prisma's
// `P2034`) instead of letting both through — this small retry wrapper
// re-runs `fn` a couple of times when that happens, which is the standard
// way to use `Serializable` (it's meant to be paired with retries, not
// used as a "never conflicts" guarantee on its own).
async function runSerializable(fn, { retries = 3 } = {}) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      // eslint-disable-next-line no-await-in-loop
      return await prisma.$transaction(fn, { isolationLevel: Prisma.TransactionIsolationLevel.Serializable });
    } catch (error) {
      if (error?.code === "P2034" && attempt < retries) {
        continue;
      }
      throw error;
    }
  }
}

// The subset of a User row that's safe to hand back to someone who has a
// legitimate relationship with them (an accepted friend, an incoming/
// outgoing request to/from them, or — see routes/groups.js — a fellow
// member of a shared group). Never used for an arbitrary/unrelated userId.
function publicUser(user) {
  return { id: user.id, displayName: user.displayName, phoneNumber: user.phoneNumber };
}

// Resolves whatever pending Invite(s) (see the Invite model's doc comment
// in prisma/schema.prisma) the just-accepted friendship's requester sent to
// the recipient's phone number before they signed up. A plain "become my
// friend" invite has nothing further to do once the friendship it was
// standing in for is ACCEPTED; an invite that also named a `groupId` gets
// the recipient added to that group right here — deliberately not any
// earlier point (see POST /auth/verify-code in routes/auth.js, which
// leaves every Invite PENDING at signup instead of granting group access
// before the recipient has actually agreed to be friends with whoever
// invited them). Must run inside the same transaction as the Friendship
// update that accepted it, and is called from both places a Friendship can
// become ACCEPTED: the explicit POST /:friendshipId/accept route below, and
// POST /request's own "they'd already requested us" auto-accept branch.
async function resolveInvitesForAcceptedFriendship(tx, friendship) {
  const recipient = await tx.user.findUnique({ where: { id: friendship.recipientId } });
  if (!recipient) return;

  const tiedInvites = await tx.invite.findMany({
    where: {
      invitingUserId: friendship.requesterId,
      invitedPhoneNumber: recipient.phoneNumber,
      status: "PENDING",
    },
  });

  for (const invite of tiedInvites) {
    // Sequential on purpose — this list is small (however many invites one
    // person sent this one phone number before it accepted their request).
    if (invite.groupId) {
      // upsert rather than create: if the inviter (or someone else) also
      // separately added this person to the same group by user id in the
      // meantime, don't fail on the GroupMembership unique constraint.
      // eslint-disable-next-line no-await-in-loop
      await tx.groupMembership.upsert({
        where: { userId_groupId: { userId: recipient.id, groupId: invite.groupId } },
        update: {},
        create: { userId: recipient.id, groupId: invite.groupId },
      });
    }
    // eslint-disable-next-line no-await-in-loop
    await tx.invite.update({
      where: { id: invite.id },
      data: { status: "RESOLVED", resolvedAt: new Date() },
    });
  }
}

// The decline-side counterpart to `resolveInvitesForAcceptedFriendship`
// above: a declined friend request must not leave its tied Invite(s)
// PENDING forever, but it also must not grant anything — CANCELLED (rather
// than RESOLVED, which is reserved for an invite that actually resulted in
// a friendship/membership) is this codebase's way of saying "this invite's
// story is over, and it never turned into group access."
async function cancelInvitesForDeclinedFriendship(tx, friendship) {
  const recipient = await tx.user.findUnique({ where: { id: friendship.recipientId } });
  if (!recipient) return;

  await tx.invite.updateMany({
    where: {
      invitingUserId: friendship.requesterId,
      invitedPhoneNumber: recipient.phoneNumber,
      status: "PENDING",
    },
    data: { status: "CANCELLED", resolvedAt: new Date() },
  });
}

const RequestFriendSchema = z.object({ phoneNumber: phoneNumberField });

// The one success result for "I sent something to this phone number" —
// deliberately identical whether that turned into a real PENDING Friendship
// (the number belongs to an existing user) or an Invite row (it doesn't).
// Returning different shapes/status codes for those two outcomes would let
// a caller send a phone number here purely to find out which one happened —
// i.e. whether that number belongs to a registered Home Eats user at all,
// with no relationship to the caller required. `FriendsListView`/
// `AddFriendView` on the iOS side don't inspect the body either way (see
// `AccountsAPIClient.sendFriendRequest`'s `sendNoContent`), so this costs
// nothing on the one client that exists today.
function requestedResult() {
  return { status: 201, body: { status: "requested" } };
}

// POST /friends/request
// Body: { phoneNumber } — the phone number of the person to friend, whether
// or not they're already a Home Eats user.
//
// - If they ARE a user: creates a PENDING Friendship from caller -> them,
//   unless a Friendship row already exists between the pair in either
//   direction (Friendship.@@unique only guards the exact same direction at
//   the database level, so the branches below check both directions and
//   reuse/flip the existing row rather than ever risking a second one).
// - If they are NOT yet a user: creates an Invite instead, which resolves
//   into a normal incoming friend request — not an instant friendship — the
//   moment that phone number signs up (see POST /auth/verify-code in
//   routes/auth.js and the Invite model's doc comment in
//   prisma/schema.prisma).
//
// Both of those two outcomes report back through the same
// `requestedResult()` — see its own doc comment on why. Everything past the
// `me`/self-friend checks runs inside one `runSerializable` transaction —
// see its own doc comment on the race this closes.
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

  const result = await runSerializable(async (tx) => {
    const target = await tx.user.findUnique({ where: { phoneNumber } });

    if (!target) {
      const existingInvite = await tx.invite.findFirst({
        where: {
          invitingUserId: req.userId,
          invitedPhoneNumber: phoneNumber,
          groupId: null,
          status: "PENDING",
        },
      });
      if (existingInvite) {
        return { status: 409, body: { error: "You've already invited this phone number." } };
      }
      await tx.invite.create({
        data: { invitingUserId: req.userId, invitedPhoneNumber: phoneNumber },
      });
      return requestedResult();
    }

    const existing = await tx.friendship.findFirst({
      where: {
        OR: [
          { requesterId: req.userId, recipientId: target.id },
          { requesterId: target.id, recipientId: req.userId },
        ],
      },
    });

    if (!existing) {
      await tx.friendship.create({
        data: { requesterId: req.userId, recipientId: target.id, status: "PENDING" },
      });
      return requestedResult();
    }

    if (existing.status === "ACCEPTED") {
      return { status: 409, body: { error: "You're already friends." } };
    }
    if (existing.status === "PENDING" && existing.requesterId === req.userId) {
      return { status: 409, body: { error: "Friend request already pending." } };
    }
    if (existing.status === "PENDING" && existing.requesterId === target.id) {
      // They'd already requested us — treat our request as accepting theirs
      // instead of leaving two one-directional requests pointed at each
      // other. This is a second place (besides POST /:friendshipId/accept
      // below) a Friendship can become ACCEPTED, so it needs the same
      // tied-Invite resolution — see `resolveInvitesForAcceptedFriendship`'s
      // own doc comment on why.
      const updatedFriendship = await tx.friendship.update({
        where: { id: existing.id },
        data: { status: "ACCEPTED" },
      });
      await resolveInvitesForAcceptedFriendship(tx, updatedFriendship);
      return { status: 200, body: { friendship: updatedFriendship, autoAccepted: true } };
    }
    // DECLINED — allow trying again, as a fresh request from us. Reuses the
    // row (updating its direction) rather than inserting a second one.
    await tx.friendship.update({
      where: { id: existing.id },
      data: { requesterId: req.userId, recipientId: target.id, status: "PENDING" },
    });
    return requestedResult();
  });

  res.status(result.status).json(result.body);
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
// Also resolves any Invite(s) the requester sent to the recipient's phone
// number before they signed up — see `resolveInvitesForAcceptedFriendship`'s
// own doc comment: this is the one moment group membership from such an
// invite is actually granted.
router.post("/:friendshipId/accept", asyncHandler(async (req, res) => {
  const friendship = await loadPendingAsRecipient(req, res);
  if (!friendship) return;
  const updated = await prisma.$transaction(async (tx) => {
    const updatedFriendship = await tx.friendship.update({
      where: { id: friendship.id },
      data: { status: "ACCEPTED" },
    });
    await resolveInvitesForAcceptedFriendship(tx, updatedFriendship);
    return updatedFriendship;
  });
  res.json({ friendship: updated });
}));

// POST /friends/:friendshipId/decline — only the recipient may decline.
// Also cancels any Invite(s) tied to this request (see
// `cancelInvitesForDeclinedFriendship`) so a declined request's tied group
// invite doesn't linger PENDING forever.
router.post("/:friendshipId/decline", asyncHandler(async (req, res) => {
  const friendship = await loadPendingAsRecipient(req, res);
  if (!friendship) return;
  const updated = await prisma.$transaction(async (tx) => {
    const updatedFriendship = await tx.friendship.update({
      where: { id: friendship.id },
      data: { status: "DECLINED" },
    });
    await cancelInvitesForDeclinedFriendship(tx, updatedFriendship);
    return updatedFriendship;
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
