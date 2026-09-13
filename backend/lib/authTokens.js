// Shared JWT signing/verifying for the two kinds of token this backend ever
// issues — used by routes/auth.js (which mints both) and
// middleware/requireAuth.js (which accepts only the first kind). Keeping
// both in one module, rather than routes/auth.js and requireAuth.js each
// calling jwt.sign/jwt.verify directly, is what makes "a purpose token can
// never be used where a session token is expected, and vice versa" a single
// well-tested boundary instead of two independently-maintained checks that
// could quietly drift apart over time.
//
// Session tokens: returned by POST /auth/login, POST /auth/complete-signup,
// and POST /auth/reset-password. No `purpose` claim, 30-day expiry — the
// normal "you're signed in" token, accepted by requireAuth on every
// authenticated route (/me, /friends, /groups, ...).
//
// Purpose tokens: returned by POST /auth/verify-code's success case. Carry
// a `purpose` claim of either "signup" (a brand-new number, or one that
// verified before but never finished signup — see the User.passwordHash
// doc comment in prisma/schema.prisma) or "reset" (an existing account with
// a password already set, i.e. forgot-password). 15-minute expiry — this
// token exists purely to bridge "just proved phone ownership via SMS" to
// "now has a password," a single follow-up call away, so it has no reason
// to outlive that window the way a real session does. See
// backend/README.md's "Accounts, friends, and groups" section for the full
// two-tier token design.
"use strict";

const jwt = require("jsonwebtoken");

const SESSION_TOKEN_EXPIRES_IN = "30d";
const PURPOSE_TOKEN_EXPIRES_IN = "15m";

const PURPOSE_SIGNUP = "signup";
const PURPOSE_RESET = "reset";

function secret() {
  return process.env.JWT_SECRET;
}

function signSessionToken(userId) {
  return jwt.sign({ userId }, secret(), { expiresIn: SESSION_TOKEN_EXPIRES_IN });
}

function signPurposeToken(userId, purpose) {
  return jwt.sign({ userId, purpose }, secret(), { expiresIn: PURPOSE_TOKEN_EXPIRES_IN });
}

// Verifies a normal session token. Throws — same contract as a bare
// jwt.verify, so callers can use one try/catch — on an invalid/expired/
// tampered token, AND on a token that decodes and signature-checks fine but
// carries a `purpose` claim. That second case is the whole point of this
// wrapper: a signup/reset token is a real, validly-signed JWT for this
// user, so without this explicit check it would otherwise pass straight
// through jwt.verify and let someone who has only proven phone ownership
// (not set a password) act as a fully signed-in user on every /me,
// /friends, /groups route. requireAuth calls this, never jwt.verify
// directly.
function verifySessionToken(token) {
  const payload = jwt.verify(token, secret());
  if (payload && typeof payload.purpose !== "undefined") {
    throw new Error("Not a session token.");
  }
  return payload;
}

// Verifies a purpose token, requiring its `purpose` claim to match
// `expectedPurpose` exactly — a signup token handed to POST
// /auth/reset-password, a reset token handed to POST /auth/complete-signup,
// or a normal session token handed to either (session tokens have no
// `purpose` claim at all, so `undefined !== "signup"/"reset"` rejects them
// the same way) must all fail, same as an outright invalid token. Throws on
// any mismatch, same "throws == invalid" contract as jwt.verify/
// verifySessionToken above.
function verifyPurposeToken(token, expectedPurpose) {
  const payload = jwt.verify(token, secret());
  if (!payload || payload.purpose !== expectedPurpose || typeof payload.userId !== "string") {
    throw new Error("Wrong token purpose.");
  }
  return payload;
}

module.exports = {
  PURPOSE_SIGNUP,
  PURPOSE_RESET,
  signSessionToken,
  signPurposeToken,
  verifySessionToken,
  verifyPurposeToken,
};
