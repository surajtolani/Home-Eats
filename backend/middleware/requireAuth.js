// Auth middleware for every route that requires a signed-in user (everything
// under /me, /friends, /groups — but not /auth/request-code or
// /auth/verify-code themselves, since those are how you get the token in
// the first place). Verifies the bearer JWT issued by POST /auth/verify-code
// and attaches the decoded user id as `req.userId`; every downstream
// handler trusts `req.userId` rather than re-deriving identity from
// anything the client sent in the body.
"use strict";

const jwt = require("jsonwebtoken");

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
    const payload = jwt.verify(match[1], process.env.JWT_SECRET);
    if (!payload || typeof payload.userId !== "string") {
      return res.status(401).json({ error: "Invalid token." });
    }
    req.userId = payload.userId;
    next();
  } catch (error) {
    // Covers both an expired token (TokenExpiredError) and a tampered/
    // malformed one (JsonWebTokenError) — the caller doesn't need to tell
    // those apart, just that they need to sign in again.
    return res.status(401).json({ error: "Invalid or expired token." });
  }
}

module.exports = { requireAuth };
