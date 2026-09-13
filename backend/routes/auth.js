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

const router = express.Router();

const PhoneSchema = z.object({
  phoneNumber: phoneNumberField,
});

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
// success, finds-or-creates the User by phone number and auto-resolves any
// pending Invites addressed to that number (see the Invite model's doc
// comment in prisma/schema.prisma), all inside one transaction so a signup
// either fully succeeds — user row, plus any invite-derived friendships and
// group memberships — or fully fails, never half-applied. Returns a JWT.
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

      // Resolve every pending invite addressed to this phone number. An
      // invite is a stronger, unambiguous mutual signal than a cold friend
      // request (someone who already knows this number specifically asked
      // for it to join them), so the resulting friendship is created
      // already ACCEPTED rather than PENDING.
      const pendingInvites = await tx.invite.findMany({
        where: { invitedPhoneNumber: phoneNumber, status: "PENDING" },
      });

      for (const invite of pendingInvites) {
        const existingFriendship = await tx.friendship.findFirst({
          where: {
            OR: [
              { requesterId: invite.invitingUserId, recipientId: newUser.id },
              { requesterId: newUser.id, recipientId: invite.invitingUserId },
            ],
          },
        });
        if (existingFriendship) {
          if (existingFriendship.status !== "ACCEPTED") {
            await tx.friendship.update({
              where: { id: existingFriendship.id },
              data: { status: "ACCEPTED" },
            });
          }
        } else {
          await tx.friendship.create({
            data: {
              requesterId: invite.invitingUserId,
              recipientId: newUser.id,
              status: "ACCEPTED",
            },
          });
        }

        if (invite.groupId) {
          // upsert rather than create: if the inviter also separately added
          // this person to the same group by user id in the meantime, don't
          // fail on the GroupMembership unique constraint.
          await tx.groupMembership.upsert({
            where: { userId_groupId: { userId: newUser.id, groupId: invite.groupId } },
            update: {},
            create: { userId: newUser.id, groupId: invite.groupId },
          });
        }

        await tx.invite.update({
          where: { id: invite.id },
          data: { status: "RESOLVED", resolvedAt: new Date() },
        });
      }

      return newUser;
    });

    const token = signToken(user.id);
    res.json({
      token,
      user: { id: user.id, phoneNumber: user.phoneNumber, displayName: user.displayName },
    });
  } catch (error) {
    console.error("Signup/verify transaction failed", error);
    res.status(500).json({ error: "Couldn't complete sign-in." });
  }
}));

module.exports = router;
