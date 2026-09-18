// POST /auth/request-code and POST /auth/verify-code — phone number + SMS
// code sign-in, backed by Twilio Verify. No password, no Apple-only
// sign-in-with-Apple: a phone number is the one identifier that works the
// same on iOS and (eventually) Android, and it's what friend-matching
// against a phone contacts list will key off of later.
//
// Neither route here requires a Bearer token (see index.js — this router is
// mounted before requireAuth would ever apply to it); everything under
// /me, /friends, /groups does.
"use strict";

const express = require("express");
const jwt = require("jsonwebtoken");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { twilioClient } = require("../lib/twilio");
const { phoneNumberField, PHONE_ERROR } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");
const { createRateLimiter } = require("../lib/rateLimit");
// Reuses routes/me.js's own `selfProfile` (attached to its exported router
// — see that file's doc comment) so this response and GET/PATCH /me's
// response can never drift apart on shape.
const meRouter = require("./me");

const router = express.Router();

const PhoneSchema = z.object({
  phoneNumber: phoneNumberField,
});

// POST /request-code costs real money the moment it fires a real Twilio
// Verify send, and that happens before Twilio's own Fraud Guard/rate
// limiting ever gets a say — so this adds a lightweight limiter in front of
// it. Per phone number, there are now TWO stacked limits rather than one:
// - `requestCodePhoneBurstLimiter` (1 per 60s) — a real incident: a user
//   received three unprompted codes in quick succession (someone who could
//   see their number — see `publicUser(...)`'s own doc comment on that
//   leak, now fixed — scripting repeated calls to this unauthenticated
//   endpoint). The old single 5/hour limit did nothing to stop a tight
//   burst like that; this catches it within the first couple of requests
//   regardless of what the hourly count still allows.
// - `requestCodePhoneLimiter` (3/hour, tightened from 5) — still comfortably
//   covers genuine spaced-out resends (typo'd a digit, code expired) while
//   capping how many real texts one number can be hit with in an hour even
//   if each individual request is more than 60s apart.
// Per IP (20/hour) stays as its own separate limit, looser since a shared
// household/office IP can plausibly have several people signing in
// independently, but still caps one IP cycling through many numbers. See
// `lib/rateLimit.js`'s own doc comment on why a small in-memory limiter is
// enough here (single Render instance, not a hard security boundary — and
// its state resets on every deploy, so this alone is a mitigation, not a
// complete fix; the real fix is not leaking phone numbers to begin with).
const requestCodePhoneBurstLimiter = createRateLimiter({ windowMs: 60 * 1000, max: 1 });
const requestCodePhoneLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 3 });
const requestCodeIPLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 20 });

function firstIssue(error, fallback) {
  return error.issues[0]?.message || fallback;
}

function signToken(userId) {
  // 30 days: long enough that a phone-based app (where re-typing an SMS
  // code every session would be actively annoying) stays signed in across
  // normal use, short enough that a leaked token doesn't work forever.
  return jwt.sign({ userId }, process.env.JWT_SECRET, { expiresIn: "30d" });
}

// POST /auth/request-code
// Body: { phoneNumber }. Starts a Twilio Verify SMS verification. Verify
// itself owns code generation, expiry, and rate-limiting/attempt-limits, so
// this route deliberately doesn't add another layer of throttling on top —
// just the cheap format check above, so a garbage input doesn't burn an
// API call.
router.post("/request-code", asyncHandler(async (req, res) => {
  const parsed = PhoneSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, PHONE_ERROR) });
  }
  const { phoneNumber } = parsed.data;

  // Checked (and counted) after body validation, so a malformed request
  // doesn't burn either quota, same reasoning as the pre-existing "cheap
  // format check before the billed Twilio call" comment below. All three
  // limiters are checked (not short-circuited) so each one's own counter
  // still advances even when another already blocks this request — a
  // caller retrying every few seconds right up against the burst limit
  // should still find the hourly limit accurately reflects how many
  // actually went through.
  const burstLimited = requestCodePhoneBurstLimiter.check(phoneNumber).limited;
  const phoneLimited = requestCodePhoneLimiter.check(phoneNumber).limited;
  const ipLimited = requestCodeIPLimiter.check(req.ip).limited;
  if (burstLimited || phoneLimited || ipLimited) {
    return res.status(429).json({ error: "Too many verification code requests. Please wait a bit and try again." });
  }

  const client = twilioClient();
  const verifyServiceSid = process.env.TWILIO_VERIFY_SERVICE_SID;
  if (!client || !verifyServiceSid) {
    return res.status(500).json({ error: "Server is missing Twilio configuration." });
  }

  try {
    await client.verify.v2.services(verifyServiceSid).verifications.create({
      to: phoneNumber,
      channel: "sms",
    });
    res.json({ ok: true });
  } catch (error) {
    // Twilio errors here cover things like an unreachable/invalid number,
    // or Verify's own rate-limiting kicking in — all of which are "this
    // request didn't work", not a bug in this server.
    console.error("Twilio Verify send failed", error);
    res.status(502).json({ error: "Couldn't send a verification code. Check the number and try again." });
  }
}));

// POST /auth/verify-code
// Body: { phoneNumber, code }. Checks the code with Twilio Verify; on
// success, finds-or-creates the User by phone number and turns any pending
// Invites addressed to that number into ordinary PENDING friend requests
// (see the Invite model's doc comment in prisma/schema.prisma — this
// deliberately does NOT auto-accept the friendship or auto-join any tied
// group; that only happens later, if and when the new user actually
// accepts the resulting request), all inside one transaction so a signup
// either fully succeeds — user row plus any invite-derived friend requests
// — or fully fails, never half-applied. Returns a JWT.
const VerifySchema = PhoneSchema.extend({
  // Twilio Verify codes are typically 4-10 digits depending on channel/
  // configuration; validated loosely here and authoritatively by Twilio.
  code: z.string().min(4).max(10),
});

router.post("/verify-code", asyncHandler(async (req, res) => {
  const parsed = VerifySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, "Invalid phoneNumber or code.") });
  }
  const { phoneNumber, code } = parsed.data;

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  const client = twilioClient();
  const verifyServiceSid = process.env.TWILIO_VERIFY_SERVICE_SID;
  if (!client || !verifyServiceSid) {
    return res.status(500).json({ error: "Server is missing Twilio configuration." });
  }

  let check;
  try {
    check = await client.verify.v2.services(verifyServiceSid).verificationChecks.create({
      to: phoneNumber,
      code,
    });
  } catch (error) {
    // Twilio throws (rather than returning a non-"approved" status) for
    // several invalid-input cases, e.g. no pending verification exists for
    // this number at all — treat that the same as a wrong/expired code
    // rather than surfacing it as a server error.
    console.error("Twilio Verify check failed", error);
    return res.status(400).json({ error: "Invalid or expired code." });
  }

  if (check.status !== "approved") {
    return res.status(400).json({ error: "Invalid or expired code." });
  }

  try {
    const user = await prisma.$transaction(async (tx) => {
      const existingUser = await tx.user.findUnique({ where: { phoneNumber } });
      if (existingUser) {
        return existingUser;
      }

      const newUser = await tx.user.create({ data: { phoneNumber } });

      // Turn every pending invite addressed to this phone number into an
      // ordinary incoming friend request — NOT an instantly-accepted
      // friendship, and NOT instant group membership even when the invite
      // named a `groupId` (see the Invite model's doc comment in
      // prisma/schema.prisma for why: both of those are deferred to the
      // moment the new user actually accepts the request, in
      // routes/friends.js). Several Invite rows can share the same inviter
      // (e.g. a bare friend invite plus one or more separate group invites
      // from the same person) — those must still collapse into exactly one
      // Friendship, not one per invite, hence deduping by inviter id here.
      const pendingInvites = await tx.invite.findMany({
        where: { invitedPhoneNumber: phoneNumber, status: "PENDING" },
      });
      const inviterIds = [...new Set(pendingInvites.map((invite) => invite.invitingUserId))];

      for (const inviterId of inviterIds) {
        // Sequential on purpose, same reasoning as the similar loops in
        // routes/groups.js — this list is small (however many people
        // happened to invite this one phone number before it signed up).
        // eslint-disable-next-line no-await-in-loop
        const existingFriendship = await tx.friendship.findFirst({
          where: {
            OR: [
              { requesterId: inviterId, recipientId: newUser.id },
              { requesterId: newUser.id, recipientId: inviterId },
            ],
          },
        });
        if (!existingFriendship) {
          // eslint-disable-next-line no-await-in-loop
          await tx.friendship.create({
            data: { requesterId: inviterId, recipientId: newUser.id, status: "PENDING" },
          });
        }
        // If a Friendship already exists between this pair (shouldn't
        // normally happen — this phone number wasn't a user yet — but stay
        // defensive), leave its current status exactly as it is rather than
        // forcing it back to PENDING.
      }

      // Every Invite row itself is deliberately left PENDING here — it only
      // moves to RESOLVED (and, if it named a groupId, grants that
      // GroupMembership) or CANCELLED once the friendship it stands in for
      // is actually accepted or declined; see
      // `resolveInvitesForAcceptedFriendship`/
      // `cancelInvitesForDeclinedFriendship` in routes/friends.js.

      return newUser;
    });

    const token = signToken(user.id);
    res.json({
      token,
      // Same full "self" shape GET/PATCH /me return (routes/me.js's
      // selfProfile, `profileComplete` included) — every caller that gets a
      // `user` object back about *themselves* should see the identical set
      // of fields, not a partial one that only fills in after a separate
      // GET /me. In particular, the iOS client needs `profileComplete`
      // available right here, immediately after verify-code, so it can
      // decide whether to route a *returning* user straight past the
      // signup name step (see RootView.swift's completion gate) without an
      // extra round-trip to GET /me first.
      user: meRouter.selfProfile(user),
    });
  } catch (error) {
    console.error("Signup/verify transaction failed", error);
    res.status(500).json({ error: "Couldn't complete sign-in." });
  }
}));

module.exports = router;
