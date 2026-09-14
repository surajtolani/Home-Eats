// Phase 5: lets someone respond to a group Invite addressed to them
// directly, rather than only ever having one resolve automatically as a
// side effect of a friendship being accepted/declined
// (`resolveInvitesForAcceptedFriendship`/`cancelInvitesForDeclinedFriendship`
// in routes/friends.js). That automatic path only ever fires on a
// friendship *transitioning* to ACCEPTED/DECLINED — which never happens for
// someone who is already an accepted friend of the inviter, since there's
// no new friendship event left to hook into for them. Phase 5's
// POST /groups/:groupId/invite (routes/groups.js) now queues a PENDING
// Invite for every addition, including an already-accepted friend, so this
// file is what makes that Invite actually visible and answerable for
// exactly that case (and, incidentally, for a not-yet-a-user recipient too,
// once they've signed up but not yet accepted the friend request the
// invite also queued for them — see routes/auth.js's POST /verify-code).
//
// Every route below is scoped to **group** Invites only (`groupId` set) —
// see `loadPendingGroupInviteAsRecipient`'s own doc comment for why a bare
// "become my friend" Invite (`groupId` null) is deliberately out of scope
// here and unaffected by any of this file.
//
// Mounted at /invites in index.js, behind requireAuth like every other
// authenticated route in this app.
"use strict";

const express = require("express");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// Same "safe to share with someone who has a legitimate relationship"
// shape as routes/friends.js's own publicUser / routes/groups.js's own
// publicUser (each file keeps its own copy rather than sharing one module —
// see groups.js's publicUser doc comment for that precedent) — here the
// relationship is "you sent/received an Invite naming this person".
function publicUser(user) {
  return { id: user.id, displayName: user.displayName, phoneNumber: user.phoneNumber };
}

// The shape returned for one pending group Invite — used by this file's own
// GET /invites below, and reused as-is by GET /notifications
// (routes/notifications.js, Part 3) so there's exactly one "what a group
// invite looks like over the wire" shape rather than a second, subtly
// different one invented for the notifications feed. `group` is
// deliberately minimal (just enough to render "Join <name>" without a
// second request, same spirit as GET /groups's own lightweight list) rather
// than the full member list GET /groups/:groupId returns — the recipient
// isn't a member yet, so most of that response wouldn't be visible to them
// anyway. `invitedBy` mirrors the `from`/`to` naming GET /friends already
// uses for the equivalent field on a friend request.
function serializeGroupInvite(invite) {
  return {
    id: invite.id,
    group: { id: invite.group.id, name: invite.group.name },
    invitedBy: publicUser(invite.invitingUser),
    createdAt: invite.createdAt,
  };
}

// Shared by GET /invites below and GET /notifications
// (routes/notifications.js) — one query for "pending group Invites waiting
// on me", not a second, separately-maintained one. Takes a phone number
// (not a userId — an Invite has no userId column at all, by design; see the
// Invite model's doc comment in prisma/schema.prisma) since that's the only
// thing an Invite is ever keyed by.
//
// `groupId: { not: null }` deliberately excludes bare "become my friend"
// Invites: unlike a group Invite, a bare Invite's only recipient-visible
// trace is meant to be the ordinary incoming Friendship row it creates once
// its phone number verifies (see routes/auth.js's POST /verify-code) — that
// Friendship already shows up in GET /friends's `incomingRequests`, so
// surfacing the underlying Invite row here too would just be the same
// pending thing shown twice, once as a friend request and once as an
// unlabeled "invite". A signed-in caller can end up with a leftover PENDING
// bare Invite sitting alongside that already-resolved-into-a-Friendship
// row (the Invite itself is deliberately left PENDING at signup — see that
// same doc comment) purely as internal bookkeeping; this filter keeps that
// bookkeeping detail from ever leaking into a response.
async function listPendingGroupInvitesFor(phoneNumber) {
  const invites = await prisma.invite.findMany({
    where: { invitedPhoneNumber: phoneNumber, status: "PENDING", groupId: { not: null } },
    include: { group: true, invitingUser: true },
    orderBy: { createdAt: "desc" },
  });
  return invites.map(serializeGroupInvite);
}

// GET /invites — the caller's own pending group Invites, matched by
// `invitedPhoneNumber == caller's phone number` (see
// `listPendingGroupInvitesFor`'s own doc comment on why this works for an
// existing user too, even though Invite has no userId column: every User
// has a known, unique phone number to match against). Kept as its own
// top-level list rather than folded into GET /groups or GET /friends —
// this is "things I haven't agreed to yet", a fundamentally different kind
// of list than "groups I'm already in" or "people I'm already
// friends-with-or-requesting". See GET /notifications
// (routes/notifications.js) for a combined feed across this and
// GET /friends's `incomingRequests` together, for a single notification
// badge/count.
router.get("/", asyncHandler(async (req, res) => {
  const me = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!me) {
    return res.status(404).json({ error: "User not found." });
  }
  const invites = await listPendingGroupInvitesFor(me.phoneNumber);
  res.json({ invites });
}));

// Shared by accept/decline below: loads the Invite, and checks it's a group
// Invite, still PENDING, and addressed to the caller's own phone number —
// sending the appropriate error response (and returning null) when any of
// that isn't true. Deliberately parallel to routes/friends.js's own
// `loadPendingAsRecipient` (same three checks, same order, same error
// shapes) rather than a differently-structured equivalent, since these two
// functions answer the same underlying question ("can this caller respond
// to this pending thing?") for the two different kinds of pending thing
// this app has.
//
// The `!invite.groupId` check is what keeps this file scoped to group
// Invites only (see this file's own header comment) — a bare "become my
// friend" Invite has no accept/decline route of its own at all (it isn't
// meant to; it resolves automatically once its phone number signs up, and
// from there is answered as an ordinary Friendship via
// POST /friends/:friendshipId/accept or /decline) — so hitting either route
// below with one gets a `400` pointing at the right place instead of either
// a confusing 404 or, worse, silently doing nothing useful with it.
async function loadPendingGroupInviteAsRecipient(req, res) {
  const invite = await prisma.invite.findUnique({ where: { id: req.params.inviteId } });
  if (!invite) {
    res.status(404).json({ error: "Invite not found." });
    return null;
  }
  if (!invite.groupId) {
    res.status(400).json({
      error:
        "This endpoint only handles group invites. A plain friend invite resolves automatically once you " +
        "sign up, and from there is answered via POST /friends/:friendshipId/accept or /decline.",
    });
    return null;
  }
  const me = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!me || invite.invitedPhoneNumber !== me.phoneNumber) {
    res.status(403).json({ error: "Only the invited phone number's account can respond to this invite." });
    return null;
  }
  if (invite.status !== "PENDING") {
    res.status(409).json({ error: `Invite is already ${invite.status.toLowerCase()}.` });
    return null;
  }
  return invite;
}

// POST /invites/:inviteId/accept — recipient only (see
// `loadPendingGroupInviteAsRecipient` above for the exact check; `403`
// otherwise). Creates the GroupMembership (as PARTICIPANT — same starting
// role every other addition path uses) and marks the Invite RESOLVED, in
// one transaction so a client never observes the Invite as resolved without
// the membership existing or vice versa.
//
// `upsert` rather than a plain `create` on the membership: mirrors
// `resolveInvitesForAcceptedFriendship`'s own reasoning in routes/friends.js
// for the exact same situation — if the caller was somehow also added to
// this group through another route in the meantime (e.g. a second,
// still-pending Invite for the same phone+group from before this feature
// tightened the "already invited" check, or a race with another accept),
// this must not fail on GroupMembership's `@@unique([userId, groupId])`
// constraint; it should just leave the existing membership as-is.
router.post("/:inviteId/accept", asyncHandler(async (req, res) => {
  const invite = await loadPendingGroupInviteAsRecipient(req, res);
  if (!invite) return;

  const updated = await prisma.$transaction(async (tx) => {
    await tx.groupMembership.upsert({
      where: { userId_groupId: { userId: req.userId, groupId: invite.groupId } },
      update: {},
      create: { userId: req.userId, groupId: invite.groupId, role: "PARTICIPANT" },
    });
    return tx.invite.update({
      where: { id: invite.id },
      data: { status: "RESOLVED", resolvedAt: new Date() },
    });
  });

  res.json({ invite: updated });
}));

// POST /invites/:inviteId/decline — recipient only, same check as accept.
// Marks the Invite DECLINED (not CANCELLED — see the InviteStatus doc
// comment in prisma/schema.prisma for why these two are kept distinct) and
// grants nothing. Declining does not delete the row or otherwise prevent a
// fresh Invite for the same phone number + group later — see
// POST /groups/:groupId/invite's own "Resend after a decline" doc comment
// in routes/groups.js for why that already works without any code here
// needing to special-case it.
router.post("/:inviteId/decline", asyncHandler(async (req, res) => {
  const invite = await loadPendingGroupInviteAsRecipient(req, res);
  if (!invite) return;

  const updated = await prisma.invite.update({
    where: { id: invite.id },
    data: { status: "DECLINED", resolvedAt: new Date() },
  });

  res.json({ invite: updated });
}));

module.exports = router;
// Attached directly to the already-exported router object — same pattern
// (and same reasoning) as routes/friends.js's `loadFriendshipsFor` export;
// see routes/notifications.js for the one other place these are called.
module.exports.listPendingGroupInvitesFor = listPendingGroupInvitesFor;
module.exports.serializeGroupInvite = serializeGroupInvite;
