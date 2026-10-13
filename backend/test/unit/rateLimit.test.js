// Covers lib/rateLimit.js's behavior when the database can't be reached.
// Normal counting needs Postgres and is covered in
// test/integration/rateLimit.test.js.
"use strict";

// Nothing listens on port 1, so every query fails fast with a connection
// error. Set before lib/prisma.js is loaded so PrismaClient picks it up.
process.env.DATABASE_URL = "postgresql://test:test@127.0.0.1:1/unreachable";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createRateLimiter } = require("../../lib/rateLimit");
const { prisma } = require("../../lib/prisma");

test.after(() => prisma.$disconnect());

// The limiter logs every database failure; keep that out of test output.
function silenceConsoleError(t) {
  t.mock.method(console, "error", () => {});
}

test("requires a name", () => {
  assert.throws(() => createRateLimiter({ windowMs: 1000, max: 1 }), /requires a name/);
});

test("failClosed limiter blocks when the database is unreachable", async (t) => {
  silenceConsoleError(t);
  const limiter = createRateLimiter({ name: "unit-closed", windowMs: 60_000, max: 5, failClosed: true });
  const result = await limiter.check("k");
  assert.deepEqual(result, { limited: true, retryAfterMs: 60_000, error: true });
});

test("default limiter allows when the database is unreachable", async (t) => {
  silenceConsoleError(t);
  const limiter = createRateLimiter({ name: "unit-open", windowMs: 60_000, max: 5 });
  const result = await limiter.check("k");
  assert.deepEqual(result, { limited: false, error: true });
});
