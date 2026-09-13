// The sign-up / log-in / forgot-password surface, backed by Twilio Verify
// for SMS and bcrypt for passwords. A phone number is still the one
// identifier that works the same on iOS and (eventually) Android, and it's
// what friend-matching against a phone contacts list keys off of later —
// but unlike the very first version of this feature, SMS is no longer
// required on every sign-in. Splitwise/WhatsApp-style "verify by SMS every
// time" was replaced by a traditional model:
//
//   - Sign up (brand-new number): POST /auth/request-code, then
//     POST /auth/verify-code (once), then POST /auth/complete-signup to set
//     a password and display name.
//   - Log in (returning user): POST /auth/login — phone number + password,
//     no SMS at all.
//   - Forgot password: POST /auth/request-code, then POST /auth/verify-code
//     again (proving you still own the phone), then
//     POST /auth/reset-password.
//
// The two-tier token model that makes this safe: POST /auth/verify-code's
// success case can no longer just log someone in the way it used to — it
// hands back a short-lived, single-purpose JWT ("signup" or "reset", see
// lib/authTokens.js) instead of a real session token. Only
// POST /auth/complete-signup, POST /auth/reset-password, and POST /auth/login
// ever hand back a real session token (the kind middleware/requireAuth.js
// accepts on /me, /friends, /groups, ...) — and each of those three purpose/
// session tokens is rejected everywhere except the one route it's meant
// for; see lib/authTokens.js's verifySessionToken/verifyPurposeToken for
// where that boundary actually lives.
//
// None of the routes here require a Bearer token (see index.js — this
// router is mounted before requireAuth would ever apply to it) — that's the
// whole point, this is how you get a token in the first place.
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { twilioClient } = require("../lib/twilio");
const { phoneNumberField, PHONE_ERROR } = require("../lib/phone");
const { asyncHandler } = require("../lib/asyncHandler");
const { createRateLimiter } = require("../lib/rateLimit");
const { passwordField, hashPassword, comparePassword, DUMMY_PASSWORD_HASH } = require("../lib/password");
const {
  PURPOSE_SIGNUP,
  PURPOSE_RESET,
  signSessionToken,
  signPurposeToken,
  verifyPurposeToken,
} = require("../lib/authTokens");

const router = express.Router();

const PhoneSchema = z.object({
  phoneNumber: phoneNumberField,
});

// POST /request-code costs real money the moment it fires a real Twilio
// Verify send, and that happens before Twilio's own Fraud Guard/rate
// limiting ever gets a say — so this adds a lightweight limiter in front of
// it. Two independent limits: per phone number (5/hour comfortably covers
// normal sign-in — typo'd a digit, code expired, resend — without letting
// someone rack up real charges hammering one number) and per IP (20/hour,
// looser since a shared household/office IP can plausibly have several
// people signing in independently, but still caps one IP cycling through
// many numbers). See `lib/rateLimit.js`'s own doc comment on why a small
// in-memory limiter is enough here (single Render instance, not a hard
// security boundary).
const requestCodePhoneLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 5 });
const requestCodeIPLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 20 });

// POST /login doesn't cost money per call the way /request-code does, but a
// phone number + password login is a real brute-force target (an attacker
// who knows/guesses a phone number gets unlimited free password guesses
// otherwise) — so it gets the same two-limiter shape. Limits are looser than
// /request-code's since a wrong password is a much more likely honest
// mistake than a mistyped SMS code (no autofill for it), but still tight
// enough to make guessing an 8+ character password impractical: 10 attempts
// per phone number per hour, 30 per IP per hour.
const loginPhoneLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 10 });
const loginIPLimiter = createRateLimiter({ windowMs: 60 * 60 * 1000, max: 30 });

function firstIssue(error, fallback) {
  return error.issues[0]?.message || fallback;
}

// The one shape every route below returns a User as — reconstructed field
// by field (never a raw Prisma row) so `passwordHash` can never leak into a
// response just because a field gets added to the model later. Matches the
// shape POST /auth/verify-code used to return before this change.
function publicUser(user) {
  return { id: user.id, phoneNumber: user.phoneNumber, displayName: user.displayName };
}

// POST /auth/request-code
// Body: { phoneNumber }. Starts a Twilio Verify SMS verification. Verify
// itself owns code generation, expiry, and rate-limiting/attempt-limits, so
// this route deliberately doesn't add another layer of throttling on top —
// just the cheap format check above, so a garbage input doesn't burn an
// API call. Purpose-agnostic: used identically for a first-time signup and
// for a forgot-password re-verification — POST /auth/verify-code is what
// decides which of those this turns out to be, based on whether the number
// already has a passwordHash set (see below).
router.post("/request-code", asyncHandler(async (req, res) => {
  const parsed = PhoneSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, PHONE_ERROR) });
  }
  const { phoneNumber } = parsed.data;

  // Checked (and counted) after body validation, so a malformed request
  // doesn't burn either quota, same reasoning as the pre-existing "cheap
  // format check before the billed Twilio call" comment below.
  const phoneLimited = requestCodePhoneLimiter.check(phoneNumber).limited;
  const ipLimited = requestCodeIPLimiter.check(req.ip).limited;
  if (phoneLimited || ipLimited) {
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
// success, looks up the User for this phone number and returns a
// short-lived, single-purpose token instead of logging anyone in directly
// (that's the core behavior change from the old SMS-every-login model —
// see the file-level comment above):
//
//   - No user yet, OR a user exists but has no passwordHash (they verified
//     before but never finished signup — see the User.passwordHash doc
//     comment in prisma/schema.prisma; this deliberately resumes that row
//     rather than losing it or erroring): creates the User if needed
//     (still resolving pending Invites exactly as before, inside the same
//     transaction), returns { signupToken, isNewAccount: true }.
//   - A user exists AND already has a passwordHash: this is a
//     forgot-password re-verification, returns
//     { resetToken, isNewAccount: false }.
//
// Either way, `signupToken`/`resetToken` is a `purpose`-scoped JWT (see
// lib/authTokens.js) good for 15 minutes and good for exactly one thing:
// POST /auth/complete-signup or POST /auth/reset-password, respectively. It
// does NOT work as a session token on any authenticated route — see
// middleware/requireAuth.js.
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
    const { user, isNewAccount } = await prisma.$transaction(async (tx) => {
      const existingUser = await tx.user.findUnique({ where: { phoneNumber } });

      if (existingUser && existingUser.passwordHash) {
        // Already a complete account — this verification was a
        // forgot-password re-proof of phone ownership, not a signup.
        return { user: existingUser, isNewAccount: false };
      }
      if (existingUser) {
        // Verified before, never finished signup (no passwordHash yet).
        // Resume the same row instead of creating a duplicate or making
        // them re-do anything already done (e.g. any invites already
        // resolved into friend requests below, the first time this number
        // verified).
        return { user: existingUser, isNewAccount: true };
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

      return { user: newUser, isNewAccount: true };
    });

    if (isNewAccount) {
      res.json({ signupToken: signPurposeToken(user.id, PURPOSE_SIGNUP), isNewAccount: true });
    } else {
      res.json({ resetToken: signPurposeToken(user.id, PURPOSE_RESET), isNewAccount: false });
    }
  } catch (error) {
    console.error("Signup/verify transaction failed", error);
    res.status(500).json({ error: "Couldn't complete verification." });
  }
}));

// POST /auth/complete-signup
// Body: { signupToken, password, displayName }. The last step of signup:
// verifies the token's signature/expiry/purpose (must be "signup" —
// see lib/authTokens.js), sets a password and display name on the user it
// names, and returns a real session token — completing signup the same way
// POST /auth/verify-code used to on its own before this change. No
// Authorization header here on purpose: `signupToken` travels as a body
// field, same as `code` does on POST /auth/verify-code, because this is
// explicitly a not-yet-fully-authenticated action (the caller has proven
// phone ownership, not signed in).
const CompleteSignupSchema = z.object({
  signupToken: z.string().min(1, "signupToken is required."),
  password: passwordField,
  displayName: z.string().trim().min(1, "displayName can't be empty.").max(100),
});

router.post("/complete-signup", asyncHandler(async (req, res) => {
  const parsed = CompleteSignupSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, "Invalid request.") });
  }
  const { signupToken, password, displayName } = parsed.data;

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  let payload;
  try {
    payload = verifyPurposeToken(signupToken, PURPOSE_SIGNUP);
  } catch (error) {
    // Covers an expired/tampered/malformed token, and a validly-signed
    // token with the wrong purpose (a resetToken, or even a real session
    // token) — all of those are "this isn't a valid signup token", and the
    // caller doesn't need finer detail than that.
    return res.status(401).json({ error: "Invalid or expired signup token." });
  }

  const passwordHash = await hashPassword(password);

  let user;
  try {
    user = await prisma.user.update({
      where: { id: payload.userId },
      data: { passwordHash, displayName },
    });
  } catch (error) {
    // The user row this token names is gone — shouldn't normally happen
    // (there's no delete-account route yet), but fail as an invalid token
    // rather than a generic 500 since that's effectively what it is from
    // the caller's point of view.
    console.error("complete-signup update failed", error);
    return res.status(400).json({ error: "Invalid or expired signup token." });
  }

  res.json({ token: signSessionToken(user.id), user: publicUser(user) });
}));

// POST /auth/reset-password
// Body: { resetToken, newPassword }. Verifies the token (must be purpose
// "reset"), updates the password, and — standard UX, no reason to make
// someone log in again right after proving who they are twice already
// (SMS, then this) — logs them straight in with a real session token.
const ResetPasswordSchema = z.object({
  resetToken: z.string().min(1, "resetToken is required."),
  newPassword: passwordField,
});

router.post("/reset-password", asyncHandler(async (req, res) => {
  const parsed = ResetPasswordSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, "Invalid request.") });
  }
  const { resetToken, newPassword } = parsed.data;

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  let payload;
  try {
    payload = verifyPurposeToken(resetToken, PURPOSE_RESET);
  } catch (error) {
    // Same "any mismatch reads as invalid" reasoning as complete-signup
    // above — a signupToken, an expired/tampered token, or a real session
    // token handed here all fail identically.
    return res.status(401).json({ error: "Invalid or expired reset token." });
  }

  const passwordHash = await hashPassword(newPassword);

  let user;
  try {
    user = await prisma.user.update({
      where: { id: payload.userId },
      data: { passwordHash },
    });
  } catch (error) {
    console.error("reset-password update failed", error);
    return res.status(400).json({ error: "Invalid or expired reset token." });
  }

  res.json({ token: signSessionToken(user.id), user: publicUser(user) });
}));

// POST /auth/login
// Body: { phoneNumber, password }. The normal, no-SMS-involved sign-in for
// a returning user. On any failure — wrong password, no such phone number,
// or a phone number that verified once but never finished signup (no
// passwordHash yet) — this returns the exact same generic 401, on purpose:
// a well-known account-enumeration protection, the same "don't let a
// response's shape/status double as a way to check who's a Home Eats user"
// principle backend/README.md's "Phone-number privacy" section already
// applies to /friends/request and /groups/:groupId/invite.
const LoginSchema = z.object({
  phoneNumber: phoneNumberField,
  // Deliberately just "non-empty" here, not the full 8-character
  // `passwordField` rule — a too-short password is still a *wrong*
  // password, and validating it more strictly here would let a caller
  // learn something about the account (or about this route's own rules)
  // beyond what the generic 401 below is supposed to reveal.
  password: z.string().min(1, "password is required."),
});

router.post("/login", asyncHandler(async (req, res) => {
  const parsed = LoginSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: firstIssue(parsed.error, "Invalid phoneNumber or password.") });
  }
  const { phoneNumber, password } = parsed.data;

  const phoneLimited = loginPhoneLimiter.check(phoneNumber).limited;
  const ipLimited = loginIPLimiter.check(req.ip).limited;
  if (phoneLimited || ipLimited) {
    return res.status(429).json({ error: "Too many login attempts. Please wait a bit and try again." });
  }

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  const user = await prisma.user.findUnique({ where: { phoneNumber } });

  // Always run a real bcrypt compare, even when there's no user or no
  // passwordHash yet — comparing against DUMMY_PASSWORD_HASH instead of
  // short-circuiting keeps this route's response time roughly the same for
  // "no such account" as for "wrong password", so timing can't be used to
  // tell those apart either (see lib/password.js's doc comment on
  // DUMMY_PASSWORD_HASH). Defense in depth on top of the generic error
  // message below, which is the primary protection.
  const passwordMatches = await comparePassword(password, user?.passwordHash ?? DUMMY_PASSWORD_HASH);

  if (!user || !user.passwordHash || !passwordMatches) {
    return res.status(401).json({ error: "Invalid phone number or password." });
  }

  res.json({ token: signSessionToken(user.id), user: publicUser(user) });
}));

module.exports = router;
