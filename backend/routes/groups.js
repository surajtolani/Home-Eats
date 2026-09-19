// Groups — the "household", but also generically any shared circle (e.g.
// "our Peru trip"): built from a user's friends list, and a user can belong
// to many groups at once. Nothing here (or in prisma/schema.prisma's
// GroupMembership model) assumes a user has only one group. Every route
// requires auth (mounted behind requireAuth in index.js).
//
// Roles (Phase 3, extended Phase 5): every GroupMembership carries a
// `role` — MANAGER or PARTICIPANT (see the GroupRole/GroupMembership doc
// comments in prisma/schema.prisma for the full reasoning and the
// migration that backfilled existing rows). The group's creator starts
// MANAGER; anyone added afterwards — via `memberUserIds` at creation, or
// once their invite is accepted (see the `POST /:groupId/invite` doc
// comment below) — starts PARTICIPANT. That split tightens
// group-*management* routes here (invite, promote/demote, and removing
// someone else): the meal-plan/grocery-list routes in
// routes/groupMealPlan.js and routes/groupGrocery.js have their own,
// separate MANAGER/PARTICIPANT rules. Phase 5 adds promote/demote
// (`POST .../members/:userId/promote`/`demote` below) — any current
// MANAGER can create more MANAGERs, so "multiple managers" was already
// fully supported by this schema and these checks before Phase 5; only the
// ability to actually change someone's role after the fact was missing.
//
// Consent (Phase 5): every path that grows a group's membership — by
// `userId` or by `phoneNumber`, whether or not the target is already an
// accepted friend of the caller — now creates/reuses a PENDING `Invite`
// instead of ever creating a `GroupMembership` directly from this route.
// See the `POST /:groupId/invite` doc comment below and
// backend/README.md's "Invites and consent" section for the full
// reasoning (short version: before Phase 5, an accepted friend could be
// added to a group with no chance to decline — this closes that gap).
// Membership is only ever actually created in routes/invites.js's
// `POST /invites/:inviteId/accept`, or — for someone who wasn't a user yet
// when invited — in `resolveInvitesForAcceptedFriendship` in
// routes/friends.js.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { phoneNumberField } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");
const { sendPush } = require("../lib/apns");

const router = express.Router();

// Same "safe to share with someone who has a legitimate relationship"
// shape as routes/friends.js's publicUser — here that relationship is
// "fellow member of this same group", checked by the caller before this is
// ever used. No `phoneNumber` — see routes/friends.js's own doc comment on
// this function for why (a real, unauthenticated abuse vector: anyone who
// could see a fellow member's phone number here could script repeated
// verification-code texts to it via the unauthenticated
// `POST /auth/request-code`).
function publicUser(user) {
  return { id: user.id, displayName: user.displayName };
}

// Same as publicUser, plus this group's role for that person — used
// anywhere a member list is returned to a fellow member (GET /:groupId,
// POST /, invite responses) so the client always knows who's a MANAGER
// without a second request.
function publicMember(membership) {
  return { ...publicUser(membership.user), role: membership.role };
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

// Shared by the leave/remove route and the demote route (Phase 5): would
// losing `targetMembership` — either by demotion to PARTICIPANT, or by
// being removed from the group entirely — leave the group with zero
// MANAGERs while other members remain? "Other members remain" is the
// important qualifier: a lone remaining member demoting themselves or
// leaving is always allowed (nobody is left to be stranded — the group
// either becomes memberless or has one ungoverned participant, neither of
// which is the "stuck, unfixable" scenario this guards against), it's only
// blocked when there'd be participants left behind with literally nobody
// who can invite new members, decide anything, or promote one of them back.
//
// Deliberately a no-op (returns false without querying anything) for a
// PARTICIPANT target — losing a PARTICIPANT can never change the group's
// MANAGER count, so both call sites can call this unconditionally instead
// of separately special-casing "target is already a PARTICIPANT" as a
// harmless no-op themselves.
async function wouldStrandGroup(groupId, targetMembership) {
  if (targetMembership.role !== "MANAGER") return false;
  const [managerCount, totalCount] = await Promise.all([
    prisma.groupMembership.count({ where: { groupId, role: "MANAGER" } }),
    prisma.groupMembership.count({ where: { groupId } }),
  ]);
  const otherMembersWouldRemain = totalCount - 1 > 0;
  const zeroManagersWouldRemain = managerCount - 1 <= 0;
  return zeroManagersWouldRemain && otherMembersWouldRemain;
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
// Body: { name, memberUserIds?: string[] } — creates a group (the caller as
// its sole initial MANAGER) and, for every id in memberUserIds, queues a
// PENDING Invite tied to the new group — the exact same consent mechanism
// POST /:groupId/invite's `userId` path uses (see that route's own doc
// comment), applied here too as of Phase 5: picking someone from your
// friends list at creation time used to add them to the group immediately,
// with no acceptance step at all, which was a real gap in Phase 5's "no
// path may ever instantly create a GroupMembership again" guarantee — this
// was the one place that guarantee didn't actually reach, since Phase 5
// only reworked POST /:groupId/invite and this route predates (and
// duplicates) that route's own member-adding logic instead of calling it.
// Every id in memberUserIds must still be one of the caller's existing
// accepted friends — same reasoning as before Phase 5: it's what stops
// someone from queuing an invite at an arbitrary stranger's userId for a
// group they share nothing with (POST /:groupId/invite's `phoneNumber`
// path is the one that may target a non-friend; this route only ever takes
// a userId, so it keeps that check).
router.post("/", asyncHandler(async (req, res) => {
  const parsed = CreateGroupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const { name, memberUserIds } = parsed.data;
  const otherMemberIds = [...new Set(memberUserIds)].filter((id) => id !== req.userId);

  const otherMembers = [];
  for (const memberId of otherMemberIds) {
    // Sequential on purpose — these are validation checks that should fail
    // fast on the first bad id, and the list is small (a group invite list,
    // not a bulk import).
    // eslint-disable-next-line no-await-in-loop
    const friends = await isAcceptedFriend(req.userId, memberId);
    if (!friends) {
      return res.status(400).json({ error: `${memberId} is not one of your accepted friends.` });
    }
    // eslint-disable-next-line no-await-in-loop
    const user = await prisma.user.findUnique({ where: { id: memberId } });
    // Can't actually happen — isAcceptedFriend above only returns true for
    // a real Friendship row, which FKs to a real User — but stay defensive
    // rather than let a null phoneNumber reach the Invite creation below.
    if (!user) {
      return res.status(404).json({ error: `${memberId} not found.` });
    }
    otherMembers.push(user);
  }

  const group = await prisma.$transaction(async (tx) => {
    const created = await tx.group.create({
      data: {
        name,
        createdByUserId: req.userId,
        memberships: { create: [{ userId: req.userId, role: "MANAGER" }] },
      },
      include: { memberships: { include: { user: true } } },
    });
    // No existing-Friendship check/creation here, unlike
    // POST /:groupId/invite's own transaction — every otherMembers entry is
    // already a validated accepted friend by this point (see the loop
    // above), so a Friendship between the caller and each of them is
    // already guaranteed ACCEPTED; that route's version of this step only
    // matters for its phoneNumber path, which can target someone who isn't
    // a friend yet at all.
    for (const user of otherMembers) {
      // Sequential on purpose, same reasoning as the validation loop above
      // — this list is the same small memberUserIds array, not a bulk
      // import, and a brand-new group can't yet have a PENDING invite race
      // to guard against the way POST /:groupId/invite's 409 check does.
      // eslint-disable-next-line no-await-in-loop
      await tx.invite.create({
        data: { invitingUserId: req.userId, invitedPhoneNumber: user.phoneNumber, groupId: created.id },
      });
    }
    return created;
  });

  res.status(201).json({
    group: {
      id: group.id,
      name: group.name,
      createdByUserId: group.createdByUserId,
      createdAt: group.createdAt,
      members: group.memberships.map(publicMember),
      defaultLocationText: group.defaultLocationText,
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

// GET /groups/:groupId — group details + member list, each member's role
// included. Phone numbers are included here since every person in the
// response is, by definition, a fellow member of this same group; a caller
// who isn't a member gets a 403 before any of that data is ever read.
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
      members: group.memberships.map(publicMember),
      defaultLocationText: group.defaultLocationText,
    },
  });
}));

const UpdateGroupSchema = z
  .object({
    name: z.string().trim().min(1, "name can't be empty.").max(200).optional(),
    // A trip group's destination ("BGC, Manila, Philippines") — see
    // Group.defaultLocationText's own doc comment in schema.prisma for
    // what this is for. `null` clears it back to "no default, use
    // whoever's asking's own current location" (the pre-existing
    // behavior); omitted leaves it unchanged, same as `name` above.
    // Trimmed empty string is treated the same as `null` below rather than
    // stored as a blank string, so a cleared text field behaves the same
    // way whether the client sent "" or an explicit null.
    defaultLocationText: z.string().trim().max(200).nullable().optional(),
  })
  .strict()
  .refine((data) => data.name !== undefined || data.defaultLocationText !== undefined, {
    message: "Provide at least one field to update.",
  });

// PATCH /groups/:groupId
// Body: { name? } and/or { defaultLocationText? } — MANAGER only. Direct
// user request: a group's name was only ever settable at creation time
// (`POST /groups`), with no way to fix a typo or rename it later; a trip
// group's default location came later, same idea. MANAGER-gated the same
// way invite/promote/demote already are (see this file's own top doc
// comment on why group *management* actions, as opposed to the meal-plan/
// grocery-list routes' own separate rules, draw that line) — a
// PARTICIPANT gets a 403, same as a non-member. Returns the same shape as
// GET /:groupId so a caller can just replace its local copy of the group
// with the response, rather than merging a partial update in by hand.
router.patch("/:groupId", asyncHandler(async (req, res) => {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  if (membership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a manager can update this group." });
  }

  const parsed = UpdateGroupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }

  const data = {};
  if (parsed.data.name !== undefined) {
    data.name = parsed.data.name;
  }
  if (parsed.data.defaultLocationText !== undefined) {
    data.defaultLocationText = parsed.data.defaultLocationText || null;
  }

  const updated = await prisma.group.update({
    where: { id: req.params.groupId },
    data,
    include: { memberships: { include: { user: true } } },
  });

  res.json({
    group: {
      id: updated.id,
      name: updated.name,
      createdByUserId: updated.createdByUserId,
      createdAt: updated.createdAt,
      members: updated.memberships.map(publicMember),
      defaultLocationText: updated.defaultLocationText,
    },
  });
}));

// POST /groups/:groupId/invite
// Body: { userId } (an existing friend) or { phoneNumber } (anyone else —
// already a Home Eats user, a user who isn't yet a friend, or not a user at
// all). MANAGER only (tightened in Phase 3 — see the GroupRole doc comment
// in prisma/schema.prisma): a PARTICIPANT can suggest meals/grocery items
// for a vote/review, but growing the group's membership is a management
// action. A caller who is a member but not a MANAGER gets a 403, same as a
// non-member.
//
// **Phase 5: no path here ever creates a GroupMembership directly anymore
// — every addition, including an already-accepted friend, goes through a
// PENDING Invite the target has to actually accept.** Before this phase,
// `userId` (always an accepted friend) and a `phoneNumber` that happened to
// match one of the caller's own accepted friends were both added
// instantly, with zero chance to decline — reasonable when this route only
// grew a group's membership among people who'd already agreed to be your
// friend, but "we're friends" and "I consent to being in this specific
// group with whoever else is in it" are genuinely different things to agree
// to (see backend/README.md's "Invites and consent" section). Now both
// paths are unified into one flow: resolve whatever was given (`userId` or
// `phoneNumber`) down to a phone number and, if it's a known user, that
// user's row — then create/reuse a PENDING Invite for that phone number +
// this `groupId`, exactly like the `phoneNumber`-to-a-stranger path always
// has. The one thing that still differs between the two input shapes is
// *validation*, not the consent step itself:
//
// - `userId` must still be one of the caller's accepted friends — same
//   restriction as group creation and as before this phase (`400`
//   otherwise). Since the caller supplied this id themselves (e.g. from
//   their own friends list), there's no new information for that `400` to
//   leak.
// - `phoneNumber` has no such restriction — it can name an accepted
//   friend, a user who isn't yet a friend, or no user at all, and every one
//   of those now takes the identical Invite path. Treating "real user, not
//   yet a friend" and "not a user at all" identically (rather than 400ing
//   the former with "must be an accepted friend") is deliberate and
//   pre-existing: a caller could otherwise send phone numbers here purely
//   to learn which ones belong to registered Home Eats users, with no
//   actual relationship to the caller required — see backend/README.md's
//   note on this. A `phoneNumber` that happens to match one of the
//   caller's own accepted friends leaks nothing new by getting the same
//   treatment (the caller already knows their own friend's number), so
//   there was never a reason to special-case it — Phase 5 removes that
//   special case entirely rather than keeping a second, only-sometimes-used
//   consent-free branch alongside the real one.
//
// Every branch reports back through the identical `invitedResponse` shape
// (`201`, `{ "status": "invited" }`) — same "no distinguishable outcomes to
// leak" reasoning as `POST /friends/request`. The Invite queued either way
// only ever turns into real GroupMembership once the recipient explicitly
// agrees: via `POST /invites/:inviteId/accept` (routes/invites.js) for
// someone who's already a user (an existing friend or not), or via
// `resolveInvitesForAcceptedFriendship` (routes/friends.js) once someone
// who wasn't yet a user signs up and then separately accepts the friend
// request that invite also queued for them.
//
// **Resend after a decline.** The "already invited" check just below only
// ever blocks on a PENDING row for this phone number + group — a prior
// invite that's since gone CANCELLED or DECLINED (see the InviteStatus doc
// comment in prisma/schema.prisma for the difference) doesn't block a fresh
// one. That means calling this route again after
// `POST /invites/:inviteId/decline` already works with no code changes
// needed beyond the check that was already here — there's deliberately no
// separate `POST /invites/:inviteId/resend` endpoint. Who may trigger a
// resend: this route stays MANAGER-only, not "only the original sender" —
// consistent with Phase 5's own multi-manager model just above (any current
// MANAGER already has equal standing to invite in the first place, so
// there's no reason one specific MANAGER would need to be the one to retry
// it) and with the fact that `invitingUserId` on the fresh Invite row is
// simply whichever MANAGER happens to call this a second time, same as the
// first.
const InviteSchema = z.union([
  z.object({ userId: z.string().uuid() }),
  z.object({ phoneNumber: phoneNumberField }),
]);

// The one success shape for "I sent/queued an Invite" — see the route's own
// doc comment above for why every branch (userId or phoneNumber, friend or
// stranger) must report back identically.
function invitedResponse(res) {
  return res.status(201).json({ status: "invited" });
}

router.post("/:groupId/invite", asyncHandler(async (req, res) => {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  if (membership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a group manager can invite new members." });
  }
  const group = await prisma.group.findUnique({ where: { id: req.params.groupId } });
  if (!group) {
    return res.status(404).json({ error: "Group not found." });
  }

  const parsed = InviteSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Provide either userId or phoneNumber." });
  }

  // Resolve either input shape down to the one thing an Invite is actually
  // keyed by (invitedPhoneNumber), plus that phone number's User row if it
  // has one yet — see the route's doc comment above for why `userId` keeps
  // its own accepted-friend check here while `phoneNumber` doesn't.
  let phoneNumber;
  let existingUser;
  if ("userId" in parsed.data) {
    const targetUserId = parsed.data.userId;
    if (!(await isAcceptedFriend(req.userId, targetUserId))) {
      return res.status(400).json({ error: "You can only add your accepted friends to a group." });
    }
    existingUser = await prisma.user.findUnique({ where: { id: targetUserId } });
    if (!existingUser) {
      // Can't actually happen — isAcceptedFriend above only returns true
      // for a real Friendship row, which FKs to a real User — but stay
      // defensive rather than let a null existingUser reach the phone
      // number access below.
      return res.status(404).json({ error: "User not found." });
    }
    phoneNumber = existingUser.phoneNumber;
  } else {
    phoneNumber = parsed.data.phoneNumber;
    existingUser = await prisma.user.findUnique({ where: { phoneNumber } });
  }

  // Already a member? Genuinely different from "already invited" below —
  // both are things the caller has a legitimate reason to be told
  // distinctly (see "Phone-number privacy" in backend/README.md) — and only
  // checkable at all when the phone number resolves to a known user.
  if (existingUser) {
    const existingMembership = await membershipFor(req.params.groupId, existingUser.id);
    if (existingMembership) {
      return res.status(409).json({ error: "That person is already a member of this group." });
    }
  }

  // The one standing-Invite path every branch now shares (see the route's
  // doc comment above). PENDING-only, on purpose — see the doc comment's
  // "Resend after a decline" paragraph for why this is also what makes a
  // fresh invite work again after a decline with no separate endpoint.
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

    // If this phone number already belongs to a user with no Friendship row
    // to the caller at all yet, send that ordinary friend request right
    // now too, same as routes/friends.js's own POST /request would — this
    // is unchanged from before Phase 5. When the two are already accepted
    // friends (the common Phase-5-motivating case: `userId`, or a
    // `phoneNumber` matching an existing friend), `existingFriendship` is
    // found here and nothing further happens to it — this block's only job
    // is to cover the "not yet any relationship at all" case, never to
    // touch an existing one. An existing Friendship in some other state
    // (already PENDING either direction, or DECLINED) is likewise left
    // untouched — this only ever creates a *fresh* request; the queued
    // Invite still stands either way, it just won't auto-resolve into
    // membership through the friendship-acceptance path unless/until that
    // separate friend-request situation is itself resolved with the caller
    // ending up as the accepted friendship's requester (irrelevant for an
    // already-accepted friend, who instead resolves this Invite directly
    // via routes/invites.js).
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

  invitedResponse(res);

  // Push after the transaction has committed, and only when `phoneNumber`
  // already belongs to a user — the same "there's an actual device to push
  // to" reasoning as routes/friends.js's own POST /request (see that
  // route's identical comment on why this happens after, not inside, the
  // transaction, and is fire-and-forget). A not-yet-a-user phone number's
  // Invite still just sits PENDING until they sign up, exactly as before.
  if (existingUser) {
    const [me, deviceTokens] = await Promise.all([
      prisma.user.findUnique({ where: { id: req.userId } }),
      prisma.deviceToken.findMany({ where: { userId: existingUser.id }, select: { token: true } }),
    ]);
    await sendPush({
      deviceTokens: deviceTokens.map((row) => row.token),
      title: "Group Invite",
      body: `${me?.displayName || me?.phoneNumber || "Someone"} invited you to join "${group.name}" on Home Eats.`,
      payload: { type: "groupInvite", groupId: req.params.groupId },
    });
  }
}));

// GET /groups/:groupId/invites — MANAGER only. Every PENDING or DECLINED
// Invite standing against this specific group, newest first — the read
// side `POST /:groupId/invite` above never got: a MANAGER needs to see who
// they (or a fellow MANAGER) have already invited and who's said no, both
// to avoid re-inviting someone with a still-PENDING invite outstanding
// (this route makes that visible up front instead of only discoverable via
// the invite route's own `409`) and to know who's worth a resend after a
// DECLINED one — resending is just calling `POST /:groupId/invite` again
// with the same target, there's no dedicated resend endpoint here either
// (see that route's own "Resend after a decline" doc comment above).
//
// **Added by the iOS-wiring task that consumes Phase 5's invite endpoints,
// not by Phase 5 itself.** Phase 5 shipped the write side
// (create/accept/decline) and the recipient's own read side
// (`GET /invites` in routes/invites.js), but nothing let a MANAGER see a
// group's own outstanding invites — which the group-detail screen's
// "Pending Invites" section needs, and `GET /:groupId` deliberately doesn't
// carry (checked directly: that route returns only `id`/`name`/
// `createdByUserId`/`createdAt`/`members`, nothing invite-shaped). Mirrors
// Phase 5's own established conventions exactly: MANAGER-only like
// invite/promote/demote above, and `serializeGroupInvite`-style minimalism
// (routes/invites.js) — but from the opposite side of the same relationship
// (who was invited, not who's inviting me), so it reuses this file's own
// `publicUser` for `invitedBy` and separately resolves each
// `invitedPhoneNumber` to a `PublicUser` when that number happens to
// already belong to one (nullable — most invited numbers, especially to a
// stranger, belong to nobody yet). Showing a fellow MANAGER an invited
// number (and, when known, the account it belongs to) leaks nothing new
// relative to what `publicMember` already exposes about every *current*
// member's phone number to that same MANAGER — the trust boundary here is
// "fellow manager of this group," identical to the one `GET /:groupId`
// already relies on.
//
// `RESOLVED` and `CANCELLED` are excluded on purpose (only PENDING/DECLINED
// come back): a RESOLVED invite is just an ordinary member now, already
// visible in this group's own member list, and a CANCELLED one's story
// ended via something else happening entirely (see the InviteStatus doc
// comment in prisma/schema.prisma) — surfacing either here would just be
// noise for what this section exists to show: who's outstanding, or worth
// a resend.
router.get("/:groupId/invites", asyncHandler(async (req, res) => {
  const membership = await membershipFor(req.params.groupId, req.userId);
  if (!membership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  if (membership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a group manager can view this group's invites." });
  }

  const invites = await prisma.invite.findMany({
    where: { groupId: req.params.groupId, status: { in: ["PENDING", "DECLINED"] } },
    include: { invitingUser: true },
    orderBy: { createdAt: "desc" },
  });

  // One extra query for every invited-and-already-a-user phone number,
  // rather than N+1 lookups inside the map below — same "batch it" instinct
  // as every other list-serializing route in this file.
  const invitedUsers = await prisma.user.findMany({
    where: { phoneNumber: { in: invites.map((invite) => invite.invitedPhoneNumber) } },
  });
  const invitedUserByPhone = new Map(invitedUsers.map((user) => [user.phoneNumber, user]));

  res.json({
    invites: invites.map((invite) => ({
      id: invite.id,
      invitedPhoneNumber: invite.invitedPhoneNumber,
      invitedUser: invitedUserByPhone.has(invite.invitedPhoneNumber)
        ? publicUser(invitedUserByPhone.get(invite.invitedPhoneNumber))
        : null,
      invitedBy: publicUser(invite.invitingUser),
      status: invite.status,
      createdAt: invite.createdAt,
    })),
  });
}));

// POST /groups/:groupId/members/:userId/promote — MANAGER only. Sets the
// target membership's role to MANAGER. A target already MANAGER is a
// harmless no-op (`200`, same response shape as an actual change) rather
// than an error — promoting is idempotent from the caller's point of view,
// and there's no "wrong precondition" here worth a 409 over (unlike demote
// below, promoting can never strand anything). No accepted-friend or
// consent check here, unlike POST /:groupId/invite above — the target is
// already a member of this same group (checked below), so there's nothing
// further to consent to; becoming a MANAGER of a group you're already in is
// not a new relationship, just an existing one gaining more capability.
router.post("/:groupId/members/:userId/promote", asyncHandler(async (req, res) => {
  const callerMembership = await membershipFor(req.params.groupId, req.userId);
  if (!callerMembership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  if (callerMembership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a group manager can promote another member." });
  }
  const targetMembership = await membershipFor(req.params.groupId, req.params.userId);
  if (!targetMembership) {
    return res.status(404).json({ error: "That user is not a member of this group." });
  }
  const updated = await prisma.groupMembership.update({
    where: { id: targetMembership.id },
    data: { role: "MANAGER" },
    include: { user: true },
  });
  res.json({ member: publicMember(updated) });
}));

// POST /groups/:groupId/members/:userId/demote — MANAGER only. Sets the
// target membership's role to PARTICIPANT, EXCEPT blocked (`409`) by
// `wouldStrandGroup` above when the target is the sole remaining MANAGER
// and other members would be left behind with nobody who can invite,
// decide, or promote one of them back — the same guard
// DELETE /:groupId/members/:userId below needs for the identical reason
// (see that route's own doc comment). A target already PARTICIPANT is a
// harmless no-op (`200`) for the same reason promote's no-op case is —
// `wouldStrandGroup` itself already returns `false` immediately for a
// non-MANAGER target, so this needs no separate no-op branch at all.
// Demoting yourself is allowed as long as it doesn't trip the same guard —
// nothing here treats "self" specially, same as promote above.
router.post("/:groupId/members/:userId/demote", asyncHandler(async (req, res) => {
  const callerMembership = await membershipFor(req.params.groupId, req.userId);
  if (!callerMembership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  if (callerMembership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a group manager can demote another member." });
  }
  const targetMembership = await membershipFor(req.params.groupId, req.params.userId);
  if (!targetMembership) {
    return res.status(404).json({ error: "That user is not a member of this group." });
  }
  if (await wouldStrandGroup(req.params.groupId, targetMembership)) {
    return res.status(409).json({
      error: "That's the only manager left in a group with other members — promote someone else first.",
    });
  }
  const updated = await prisma.groupMembership.update({
    where: { id: targetMembership.id },
    data: { role: "PARTICIPANT" },
    include: { user: true },
  });
  res.json({ member: publicMember(updated) });
}));

// DELETE /groups/:groupId/members/:userId — leave (pass your own id) or
// remove another member. Leaving is always self-service regardless of role
// (a PARTICIPANT can always remove themselves); removing someone ELSE is
// MANAGER only (tightened in Phase 3 — see the GroupRole doc comment in
// prisma/schema.prisma). A caller who isn't a member themselves gets a 403.
//
// Phase 5: also guarded by `wouldStrandGroup` above — a self-leave or a
// manager-removing-another-member is blocked (`409`) when the target is
// the group's sole remaining MANAGER and other members would be left
// behind with nobody who can invite new members, decide anything, or
// promote one of them back. This was a known, previously-unfixable gap:
// before Phase 5 added promote/demote, there was no way for a stuck group
// to recover from losing its last manager (nobody left who could grant
// anyone the MANAGER role), so blocking the removal outright was the only
// real option anyway and would have just relocated the problem — "you
// can't leave/remove them, and you also can't fix it" is not much better
// than "you can leave/remove them, and now nobody can fix it". Now that
// `POST .../promote` exists, the fix is real (promote someone else first),
// so this guard is worth adding. Removing/leaving as a PARTICIPANT, or as a
// MANAGER when at least one other MANAGER remains, or as the group's last
// member overall (nobody would be left to strand — see `wouldStrandGroup`'s
// own doc comment), are all still unaffected.
router.delete("/:groupId/members/:userId", asyncHandler(async (req, res) => {
  const callerMembership = await membershipFor(req.params.groupId, req.userId);
  if (!callerMembership) {
    return res.status(403).json({ error: "You're not a member of this group." });
  }
  const isSelf = req.params.userId === req.userId;
  if (!isSelf && callerMembership.role !== "MANAGER") {
    return res.status(403).json({ error: "Only a group manager can remove another member." });
  }
  const targetMembership = isSelf ? callerMembership : await membershipFor(req.params.groupId, req.params.userId);
  if (!targetMembership) {
    return res.status(404).json({ error: "That user is not a member of this group." });
  }
  if (await wouldStrandGroup(req.params.groupId, targetMembership)) {
    return res.status(409).json({
      error: "That's the only manager left in a group with other members — promote someone else first.",
    });
  }
  await prisma.groupMembership.delete({ where: { id: targetMembership.id } });
  res.status(204).end();
}));

module.exports = router;
