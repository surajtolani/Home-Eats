// Auth middleware for every route that requires a signed-in user (everything
// under /me, /friends, /groups — but not any of the /auth/* routes
// themselves, since those are how you get a token in the first place).
// Verifies the bearer JWT and attaches the decoded user id as `req.userId`;
// every downstream handler trusts `req.userId` rather than re-deriving
// identity from anything the client sent in the body.
//
// Only accepts a real *session* token — one returned by POST /auth/login,
// POST /auth/complete-signup, or POST /auth/reset-password. It deliberately
// does NOT accept the short-lived "signup"/"reset" purpose tokens
// POST /auth/verify-code returns (see lib/authTokens.js) — those exist only
// to bridge "just proved phone ownership via SMS" to "now has a password",
// not to authenticate as the user on every other route. That rejection
// lives in `verifySessionToken` itself (it throws on any token carrying a
// `purpose` claim) rather than being duplicated here, so there's exactly
// one place that decides what counts as a valid session token.
"use strict";

const { verifySessionToken } = require("../lib/authTokens");

function requireAuth(req, res, next) {
  const header = req.get("authorization") || "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return res.status(401).json({ error: "Missing or malformed Authorization header." });
  }

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  try {
    const payload = verifySessionToken(match[1]);
    if (!payload || typeof payload.userId !== "string") {
      return res.status(401).json({ error: "Invalid token." });
    }
    req.userId = payload.userId;
    next();
  } catch (error) {
    // Covers an expired token (TokenExpiredError), a tampered/malformed one
    // (JsonWebTokenError), and a validly-signed purpose token used here
    // (verifySessionToken's own thrown Error) — the caller doesn't need to
    // tell those apart, just that they need to sign in again.
    return res.status(401).json({ error: "Invalid or expired token." });
  }
}

module.exports = { requireAuth };
