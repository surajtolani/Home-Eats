"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { setTimeout: sleep } = require("node:timers/promises");
const { useTestDatabase, startTestServer, resetDatabase } = require("../helpers/server");

// Unique per run so limiters in these tests never share buckets with each
// other or with an earlier run.
function uniqueName(label) {
  return `test-${label}-${crypto.randomUUID()}`;
}

// Windows are aligned to multiples of windowMs. If the current window is
// about to end, wait for the next one so a test's hits all land in one.
async function waitForFreshWindow(windowMs, neededMs) {
  const remaining = windowMs - (Date.now() % windowMs);
  if (remaining < neededMs) await sleep(remaining + 5);
}

test("durable rate limiter", async (t) => {
  if (!useTestDatabase()) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  const { createRateLimiter, sweepExpiredBuckets } = require("../../lib/rateLimit");
  const { prisma } = require("../../lib/prisma");
  t.after(() => prisma.$disconnect());

  const windowMs = 60 * 60 * 1000;

  await t.test("max + 1 is limited", async () => {
    await waitForFreshWindow(windowMs, 5000);
    const limiter = createRateLimiter({ name: uniqueName("max"), windowMs, max: 2 });
    assert.equal((await limiter.check("k")).limited, false);
    assert.equal((await limiter.check("k")).limited, false);
    const third = await limiter.check("k");
    assert.equal(third.limited, true);
    assert.ok(third.retryAfterMs > 0 && third.retryAfterMs <= windowMs);
  });

  await t.test("a new limiter with the same name (a restart) sees earlier hits", async () => {
    await waitForFreshWindow(windowMs, 5000);
    const name = uniqueName("restart");
    const before = createRateLimiter({ name, windowMs, max: 2 });
    await before.check("k");
    await before.check("k");
    const after = createRateLimiter({ name, windowMs, max: 2 });
    assert.equal((await after.check("k")).limited, true);
  });

  await t.test("20 concurrent checks with max 5 allow exactly 5", async () => {
    await waitForFreshWindow(windowMs, 5000);
    const limiter = createRateLimiter({ name: uniqueName("concurrent"), windowMs, max: 5 });
    const results = await Promise.all(Array.from({ length: 20 }, () => limiter.check("k")));
    assert.equal(results.filter((r) => !r.limited).length, 5);
    assert.ok(results.every((r) => !r.error));
  });

  await t.test("different names with the same key don't interfere", async () => {
    await waitForFreshWindow(windowMs, 5000);
    const a = createRateLimiter({ name: uniqueName("a"), windowMs, max: 1 });
    const b = createRateLimiter({ name: uniqueName("b"), windowMs, max: 1 });
    assert.equal((await a.check("same-key")).limited, false);
    assert.equal((await a.check("same-key")).limited, true);
    assert.equal((await b.check("same-key")).limited, false);
  });

  await t.test("different keys under one name don't interfere", async () => {
    await waitForFreshWindow(windowMs, 5000);
    const limiter = createRateLimiter({ name: uniqueName("keys"), windowMs, max: 1 });
    assert.equal((await limiter.check("x")).limited, false);
    assert.equal((await limiter.check("x")).limited, true);
    assert.equal((await limiter.check("y")).limited, false);
  });

  await t.test("a new window starts a fresh count", async () => {
    const shortWindowMs = 200;
    await waitForFreshWindow(shortWindowMs, 100);
    const limiter = createRateLimiter({ name: uniqueName("window"), windowMs: shortWindowMs, max: 1 });
    assert.equal((await limiter.check("k")).limited, false);
    assert.equal((await limiter.check("k")).limited, true);
    await sleep(shortWindowMs + 20);
    assert.equal((await limiter.check("k")).limited, false);
  });

  await t.test("the sweep deletes long-expired buckets and keeps current ones", async () => {
    const hourMs = 60 * 60 * 1000;
    const oldKey = `${uniqueName("sweep-old")}:k`;
    const recentKey = `${uniqueName("sweep-recent")}:k`;
    const now = Date.now();
    // Window ended 3 hours ago: past the 1-hour grace period.
    await prisma.rateLimitBucket.create({
      data: { key: oldKey, windowStart: new Date(now - 4 * hourMs), count: 1, expiresAt: new Date(now - 3 * hourMs) },
    });
    // Window ended 10 minutes ago: still inside the grace period.
    await prisma.rateLimitBucket.create({
      data: { key: recentKey, windowStart: new Date(now - hourMs), count: 1, expiresAt: new Date(now - 10 * 60 * 1000) },
    });
    const live = createRateLimiter({ name: uniqueName("sweep-live"), windowMs, max: 5 });
    await live.check("k");

    await sweepExpiredBuckets();

    assert.equal(await prisma.rateLimitBucket.count({ where: { key: oldKey } }), 0);
    assert.equal(await prisma.rateLimitBucket.count({ where: { key: recentKey } }), 1);
    assert.equal(await prisma.rateLimitBucket.count({ where: { key: { startsWith: "test-sweep-live-" } } }), 1);
  });
});

test("POST /auth/request-code", async (t) => {
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(() => server.close());
  await resetDatabase();
  // The route logs every request; keep that out of test output.
  t.mock.method(console, "log", () => {});

  await t.test("a second request for the same number within a minute gets 429", async () => {
    // The burst limiter allows 1 per 60-second window.
    await waitForFreshWindow(60 * 1000, 5000);
    const send = () =>
      fetch(`${server.baseURL}/auth/request-code`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ phoneNumber: "+14155550123" }),
      });
    // The first request passes every limiter and then fails on purpose,
    // because Twilio isn't configured in tests (500). That still counts.
    const first = await send();
    assert.notEqual(first.status, 429);
    const second = await send();
    assert.equal(second.status, 429);
  });
});
