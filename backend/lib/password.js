// Password hashing for the sign-up/log-in/forgot-password flow in
// routes/auth.js. Uses `bcryptjs` (a pure-JS reimplementation of bcrypt,
// not the native `bcrypt` package) specifically to avoid node-gyp/native
// compilation at `npm install` time on Render — same "keep the deploy
// simple" reasoning as the Prisma 6.x pin in prisma/schema.prisma. It's
// slower than the native module at high volume, but this app is nowhere
// near a scale where that matters.
"use strict";

const bcrypt = require("bcryptjs");
const { z } = require("zod");

// 10 rounds is bcryptjs's own recommended default — a reasonable balance of
// "expensive enough to blunt offline brute-forcing" and "fast enough not to
// noticeably slow down login" at this app's scale.
const SALT_ROUNDS = 10;

// Enforced server-side (via `passwordField` below) regardless of whatever
// the iOS client separately validates — never trust a length check that
// only exists on the client.
const MIN_PASSWORD_LENGTH = 8;

const passwordField = z
  .string()
  .min(MIN_PASSWORD_LENGTH, `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`);

function hashPassword(password) {
  return bcrypt.hash(password, SALT_ROUNDS);
}

function comparePassword(password, hash) {
  return bcrypt.compare(password, hash);
}

// A precomputed hash of a fixed, throwaway string — never a real password —
// that POST /auth/login compares against when the phone number given
// doesn't match any user, or matches a user with no passwordHash yet (see
// the User.passwordHash doc comment in prisma/schema.prisma). Without this,
// that route would return in "no such row" time for a number that isn't a
// user at all, but "no such row" plus "run a real bcrypt compare" time for
// one that is — a timing side-channel that could let someone distinguish
// "no such account" from "wrong password" even though both cases return the
// exact same generic 401 (see routes/auth.js). Computed once at process
// start with the synchronous bcrypt call — that's fine here, it happens
// once per process, never per-request.
const DUMMY_PASSWORD_HASH = bcrypt.hashSync("home-eats-dummy-hash-for-timing-safety", SALT_ROUNDS);

module.exports = { MIN_PASSWORD_LENGTH, passwordField, hashPassword, comparePassword, DUMMY_PASSWORD_HASH };
