// GET /me and PATCH /me — the caller's own profile. Both require auth (see
// index.js, which applies requireAuth before mounting this router).
"use strict";

const express = require("express");
const { z } = require("zod");
const { prisma } = require("../lib/prisma");
const { asyncHandler } = require("../lib/asyncHandler");

const router = express.Router();

// True once every one of the five "mandatory profile" fields (see the
// `User` model's doc comment in prisma/schema.prisma) is a non-empty
// string. Computed here, server-side, rather than left for each client to
// re-derive from the raw fields: the iOS app needs this exact same
// five-field check in two independent places (`RootView`'s completion
// gate, and to decide whether the signup name step can be skipped for an
// already-complete account), and duplicating "are all five of these
// truthy" client-side is exactly the kind of thing that quietly drifts
// out of sync with the server's own idea of "complete" the moment a sixth
// field is ever added here. One caveat worth calling out: a field holding
// only whitespace would pass this `Boolean(...)` check even though
// `UpdateMeSchema` below never actually lets one get saved that way
// (`.trim().min(1)` rejects it) — the two are enforced by different code
// paths but agree in practice, since this is the only route that ever
// writes these columns.
function computeProfileComplete(user) {
  return Boolean(
    user.firstName &&
      user.lastName &&
      user.city &&
      user.state &&
      user.country
  );
}

// Shared between GET and PATCH's response so the two never drift — every
// profile field a caller can see/set about themselves.
function selfProfile(user) {
  return {
    id: user.id,
    phoneNumber: user.phoneNumber,
    displayName: user.displayName,
    firstName: user.firstName,
    lastName: user.lastName,
    city: user.city,
    state: user.state,
    country: user.country,
    createdAt: user.createdAt,
    profileComplete: computeProfileComplete(user),
  };
}

router.get("/", asyncHandler(async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.userId } });
  if (!user) {
    // The JWT was valid but the user row is gone — shouldn't normally
    // happen (there's no delete-account flow yet), but fail clearly rather
    // than pretending the profile exists.
    return res.status(404).json({ error: "User not found." });
  }
  res.json({ user: selfProfile(user) });
}));

// Every field here is independently optional — a partial update, same
// "omitted key means leave it alone" semantics as recipe-library's PATCH
// (see routes/recipeLibrary.js) — but unlike that route, nothing here is
// ever meant to be explicitly clearable back to null (a phone number
// always has some plausible first/last name eventually; there's no "clear
// your city" use case worth the extra omit-vs-null plumbing that route
// needed for a recipe's optional summary), so a plain `.optional()` field
// per key is enough. `.refine` below just rejects a genuinely empty
// request rather than silently no-op'ing it.
//
// Note this schema's optionality is a distinct concept from "required to
// finish onboarding" (see `computeProfileComplete` above and
// `RootView.swift`'s completion gate): this PATCH endpoint is deliberately
// still a partial-update endpoint — a client filling in five fields one at
// a time (e.g. the signup name step, which saves after every field is
// typed) needs each individual PATCH to succeed without having to resend
// every other field it doesn't have yet. "Required" is entirely a
// client-side gate on top of this same endpoint, not a change to what this
// endpoint itself accepts.
const UpdateMeSchema = z
  .object({
    displayName: z.string().trim().min(1, "displayName can't be empty.").max(100).optional(),
    firstName: z.string().trim().min(1, "firstName can't be empty.").max(100).optional(),
    lastName: z.string().trim().min(1, "lastName can't be empty.").max(100).optional(),
    city: z.string().trim().min(1, "city can't be empty.").max(100).optional(),
    state: z.string().trim().min(1, "state can't be empty.").max(100).optional(),
    country: z.string().trim().min(1, "country can't be empty.").max(100).optional(),
  })
  .refine((data) => Object.keys(data).length > 0, {
    message: "Provide at least one field to update.",
  });

router.patch("/", asyncHandler(async (req, res) => {
  const parsed = UpdateMeSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }

  // `parsed.data` only contains the keys actually present in the request
  // body (zod's `.optional()` fields simply aren't present in the parsed
  // output when omitted, no `.default()` involved) — safe to spread
  // straight into Prisma's `data` as a genuine partial update.
  const user = await prisma.user.update({
    where: { id: req.userId },
    data: parsed.data,
  });
  res.json({ user: selfProfile(user) });
}));

// POST /me/device-token
// Body: { token } — registers this device's APNs token against the
// signed-in caller, so a push (routes/friends.js, routes/groups.js — see
// lib/apns.js) actually has somewhere to go for them. Called by the iOS
// client's `PushNotificationService` at launch and right after sign-in —
// see that type's own doc comment.
//
// Upserts on `token` (not `userId`), matching `DeviceToken.token`'s own
// `@unique` constraint (see its doc comment in prisma/schema.prisma): the
// exact same token string can legitimately move to a *different* user over
// time — an uninstall/reinstall, a restore to a different Apple ID, or
// simply someone else's account signing into the same physical device
// later. Re-registering the same token for a new `userId` should silently
// repoint that one row at its new owner, not collide, and definitely not
// leave the old owner still receiving pushes meant for someone else.
const DeviceTokenSchema = z.object({
  token: z.string().trim().min(1, "token is required.").max(500),
});

router.post("/device-token", asyncHandler(async (req, res) => {
  const parsed = DeviceTokenSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.issues[0]?.message || "Invalid request." });
  }
  const { token } = parsed.data;

  await prisma.deviceToken.upsert({
    where: { token },
    update: { userId: req.userId },
    create: { token, userId: req.userId },
  });
  res.status(204).end();
}));

// `selfProfile` is attached to the exported router (an Express `Router()`
// is itself just a function, so it can carry extra properties fine) rather
// than exported as a second top-level value, so `index.js`'s existing
// `const meRouter = require("./routes/me")` — used directly as
// middleware — keeps working unchanged. routes/auth.js's verify-code
// response reuses this exact function for its own `user` field: that
// response needs the identical shape (`profileComplete` included) GET/
// PATCH /me return, and duplicating this object literal (and
// `computeProfileComplete`'s five-field check) a second time in auth.js is
// exactly the kind of copy that quietly drifts the moment a sixth profile
// field is added here later.
router.selfProfile = selfProfile;

module.exports = router;
