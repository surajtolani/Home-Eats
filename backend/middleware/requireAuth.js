// Auth middleware for every route that requires a signed-in user (everything
// under /me, /friends, /groups — but not /auth/request-code or
// /auth/verify-code themselves, since those are how you get the token in
// the first place). Verifies the bearer JWT issued by POST /auth/verify-code
// and attaches the decoded user id as `req.userId`; every downstream
// handler trusts `req.userId` rather than re-deriving identity from
// anything the client sent in the body.
"use strict";

const jwt = require("jsonwebtoken");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

async function requireAuthHandler(req, res, next) {
  const header = req.get("authorization") || "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return res.status(401).json({ error: "Missing or malformed Authorization header." });
  }

  if (!process.env.JWT_SECRET) {
    console.error("JWT_SECRET is not configured.");
    return res.status(500).json({ error: "Server is misconfigured." });
  }

  let payload;
  try {
    // `algorithms` pinned explicitly, not left to jsonwebtoken's own
    // type-based inference — this app only ever signs with a symmetric
    // HS256 secret (no RSA/EC key anywhere), so there's no live
    // algorithm-confusion vector today, but stating the one accepted
    // method here keeps that true by construction rather than by
    // coincidence if the signing setup ever changes.
    payload = jwt.verify(match[1], process.env.JWT_SECRET, { algorithms: ["HS256"] });
  } catch (error) {
    // Covers both an expired token (TokenExpiredError) and a tampered/
    // malformed one (JsonWebTokenError) — the caller doesn't need to tell
    // those apart, just that they need to sign in again.
    return res.status(401).json({ error: "Invalid or expired token." });
  }
  if (!payload || typeof payload.userId !== "string") {
    return res.status(401).json({ error: "Invalid token." });
  }

  // `tokenVersion` — a leaked/stolen token used to stay valid for its full
  // 30-day life with no way to cut it short (see User.tokenVersion's own
  // doc comment in prisma/schema.prisma). A token issued before the
  // user's current tokenVersion is treated exactly like an expired one:
  // whoever holds it has to sign in again. This is the one extra query
  // `requireAuth` didn't used to make — worth it for every other route on
  // this server to gain a real revocation mechanism for free.
  const user = await prisma.user.findUnique({ where: { id: payload.userId }, select: { tokenVersion: true } });
  if (!user || (payload.tokenVersion ?? 0) !== user.tokenVersion) {
    return res.status(401).json({ error: "Invalid or expired token." });
  }

  req.userId = payload.userId;
  next();
}

// Wrapped with asyncHandler — this middleware is now async (the added
// tokenVersion lookup awaits a Prisma call), and Express 4 does not catch a
// rejected promise from a plain async middleware on its own; an unhandled
// rejection there would hang the request instead of returning an error. See
// asyncHandler's own doc comment for why every other async handler in this
// codebase already goes through it.
const requireAuth = asyncHandler(requireAuthHandler);

module.exports = { requireAuth };
