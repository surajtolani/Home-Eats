// A tiny in-memory fixed-window rate limiter. This process runs as a single
// instance on Render (see backend/README.md) — no Redis or other external
// store is needed at this scale, just a `Map` keyed by whatever the caller
// wants to throttle (a phone number, an IP, ...). State lives only in this
// process's memory: it resets on every deploy/restart and isn't shared
// across instances if this ever moves to more than one. That's an
// acceptable trade-off here — this exists to blunt casual abuse of a route
// that costs real money per call (Twilio Verify), not to serve as a hard
// security boundary that must survive restarts.
"use strict";

function createRateLimiter({ windowMs, max }) {
  const hits = new Map(); // key -> { count, resetAt }

  // Checks (and, if not already over the limit, counts) one attempt for
  // `key`. Returns `{ limited: false }` if this attempt is allowed, or
  // `{ limited: true, retryAfterMs }` if `key` has already used up its
  // quota for the current window.
  function check(key) {
    const now = Date.now();
    const entry = hits.get(key);
    if (!entry || now >= entry.resetAt) {
      hits.set(key, { count: 1, resetAt: now + windowMs });
      return { limited: false };
    }
    if (entry.count >= max) {
      return { limited: true, retryAfterMs: entry.resetAt - now };
    }
    entry.count += 1;
    return { limited: false };
  }

  // Periodic sweep so `hits` doesn't grow without bound over the process's
  // lifetime with stale entries for keys that stopped showing up.
  // `unref()` so this timer never keeps the process alive on its own (it
  // shouldn't block a normal shutdown).
  const sweep = setInterval(() => {
    const sweepNow = Date.now();
    for (const [key, entry] of hits) {
      if (sweepNow >= entry.resetAt) hits.delete(key);
    }
  }, windowMs);
  if (typeof sweep.unref === "function") sweep.unref();

  return { check };
}

module.exports = { createRateLimiter };
