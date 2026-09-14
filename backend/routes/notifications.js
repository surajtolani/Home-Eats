// Phase 5, Part 3: a single "things waiting on my response" feed, built
// entirely on top of two pre-existing sources rather than a new table or a
// third notion of "notification" — see backend/README.md's "Notifications"
// section for the full picture:
//
// 1. Incoming friend requests — the exact same list GET /friends already
//    returns as `incomingRequests` (routes/friends.js's
//    `loadFriendshipsFor`).
// 2. Incoming group Invites — the exact same list GET /invites already
//    returns (routes/invites.js's `listPendingGroupInvitesFor`).
//
// This route deliberately does not introduce a third serialization shape
// for either kind of item: `friendRequests` below is exactly what
// `incomingRequests` already looks like elsewhere, and `groupInvites` is
// exactly what `GET /invites`'s `invites` already looks like — a client
// that already knows how to render one of those lists (e.g. on the
// dedicated Friends or Invites screens) needs no new parsing logic to also
// render this combined one. `count` is just the sum of both lists' lengths,
// for a notification-bell badge that doesn't need to know or care what
// kind of thing is pending — only that something is.
//
// Deliberately read-only: nothing here resolves/dismisses anything by
// itself. Responding to an item still goes through its own existing route
// (POST /friends/:friendshipId/accept|decline, or
// POST /invites/:inviteId/accept|decline) — this endpoint exists purely to
// answer "what's pending" in one request instead of two.
//
// Mounted at /notifications in index.js, behind requireAuth like every
// other authenticated route in this app.
"use strict";

const express = require("express");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");
const friendsRouter = require("./friends");
const invitesRouter = require("./invites");

const router = express.Router();

// GET /notifications
// Returns { count, friendRequests, groupInvites } — see this file's own
// header comment for exactly what each of those is and where it comes
// from. The two sources are independent of each other (a friend request
// touches no Invite row, and vice versa for a group Invite to an
// already-accepted friend — see routes/invites.js's own doc comment), so
// they're fetched in parallel rather than sequentially.
router.get("/", asyncHandler(async (req, res) => {
  const me = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!me) {
    return res.status(404).json({ error: "User not found." });
  }

  const [{ incomingRequests }, groupInvites] = await Promise.all([
    friendsRouter.loadFriendshipsFor(req.userId),
    invitesRouter.listPendingGroupInvitesFor(me.phoneNumber),
  ]);

  res.json({
    count: incomingRequests.length + groupInvites.length,
    friendRequests: incomingRequests,
    groupInvites,
  });
}));

module.exports = router;
