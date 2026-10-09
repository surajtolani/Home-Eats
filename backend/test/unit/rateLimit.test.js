"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { setTimeout: sleep } = require("node:timers/promises");
const { createRateLimiter } = require("../../lib/rateLimit");

test("allows max hits, then blocks the next one", () => {
  const limiter = createRateLimiter({ windowMs: 60_000, max: 3 });
  for (let i = 0; i < 3; i += 1) {
    assert.equal(limiter.check("k").limited, false, `hit ${i + 1} should be allowed`);
  }
  const blocked = limiter.check("k");
  assert.equal(blocked.limited, true);
  assert.ok(blocked.retryAfterMs > 0);
});

test("keys are counted independently", () => {
  const limiter = createRateLimiter({ windowMs: 60_000, max: 1 });
  assert.equal(limiter.check("a").limited, false);
  assert.equal(limiter.check("a").limited, true);
  assert.equal(limiter.check("b").limited, false);
});

test("resets after windowMs", async () => {
  const limiter = createRateLimiter({ windowMs: 50, max: 1 });
  assert.equal(limiter.check("k").limited, false);
  assert.equal(limiter.check("k").limited, true);
  await sleep(70);
  assert.equal(limiter.check("k").limited, false);
});
