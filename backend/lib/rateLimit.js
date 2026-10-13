// A fixed-window rate limiter whose counters live in Postgres (the
// `RateLimitBucket` table in prisma/schema.prisma), so limits survive
// deploys and restarts and would be shared across instances. It used to be
// an in-memory `Map`, which gave every caller a fresh allowance after each
// deploy.
//
// Each check is one atomic upsert-and-increment, so concurrent requests
// can't both slip under the limit. Blocked attempts are counted too, on
// purpose: a caller hammering an endpoint stays blocked.
"use strict";

const { prisma } = require("./prisma");

const SWEEP_INTERVAL_MS = 10 * 60 * 1000;
// How long a bucket is kept after its window ends before the sweep deletes it.
const SWEEP_GRACE_MS = 60 * 60 * 1000;
// What a fail-closed limiter tells the caller to wait when the database is
// unreachable.
const FAIL_CLOSED_RETRY_AFTER_MS = 60 * 1000;

let sweepTimer = null;

// Deletes buckets whose window ended more than SWEEP_GRACE_MS ago. Resolves
// to the number of rows deleted. The cutoff is computed here and bound as a
// parameter, rather than using SQL now(): Prisma stores DateTime as UTC in a
// timestamp-without-time-zone column, and now() would be shifted by the
// session's time zone.
function sweepExpiredBuckets() {
  const cutoff = new Date(Date.now() - SWEEP_GRACE_MS);
  return prisma.$executeRaw`DELETE FROM "RateLimitBucket" WHERE "expiresAt" < ${cutoff}`;
}

// Started lazily on the first check so that merely requiring this module
// (in tests, or in scripts) never opens a timer. `unref()` so the timer
// never keeps the process alive on its own.
function ensureSweepStarted() {
  if (sweepTimer) return;
  sweepTimer = setInterval(() => {
    sweepExpiredBuckets().catch((error) => {
      console.error("Rate limit sweep failed", error);
    });
  }, SWEEP_INTERVAL_MS);
  if (typeof sweepTimer.unref === "function") sweepTimer.unref();
}

// `name` namespaces limiters that share a caller key (for example a phone
// number checked by both request-code and verify-code). `failClosed`
// decides what happens if the database errors during a check: true blocks
// the request (for SMS-sending and sign-in routes, where letting traffic
// through unthrottled is the bigger risk), false logs and allows it.
function createRateLimiter({ name, windowMs, max, failClosed = false }) {
  if (!name) throw new Error("createRateLimiter requires a name.");

  // Counts one attempt for `key`. Resolves to `{ limited: false }` if it's
  // allowed, or `{ limited: true, retryAfterMs }` if `key` has used up its
  // quota for the current window. `error: true` is added when the database
  // check itself failed.
  async function check(key) {
    ensureSweepStarted();
    const now = Date.now();
    const windowStart = new Date(Math.floor(now / windowMs) * windowMs);
    const expiresAt = new Date(windowStart.getTime() + windowMs);
    const bucketKey = `${name}:${key}`;

    try {
      // Tagged template: every ${...} below is sent as a bound parameter,
      // never spliced into the SQL text. Don't switch this to
      // $queryRawUnsafe or build the string by hand (SQL injection).
      const rows = await prisma.$queryRaw`
        INSERT INTO "RateLimitBucket" ("key", "windowStart", "count", "expiresAt")
        VALUES (${bucketKey}, ${windowStart}, 1, ${expiresAt})
        ON CONFLICT ("key", "windowStart")
        DO UPDATE SET "count" = "RateLimitBucket"."count" + 1
        RETURNING "count"`;
      const count = Number(rows[0].count);
      if (count > max) {
        return { limited: true, retryAfterMs: Math.max(0, expiresAt.getTime() - now) };
      }
      return { limited: false };
    } catch (error) {
      console.error(`Rate limiter "${name}" check failed (${failClosed ? "blocking" : "allowing"} request)`, error);
      if (failClosed) {
        return { limited: true, retryAfterMs: FAIL_CLOSED_RETRY_AFTER_MS, error: true };
      }
      return { limited: false, error: true };
    }
  }

  return { check };
}

// All-or-nothing check-and-reserve across several quotas, for actions where
// a fixed window isn't strict enough and a blocked attempt mustn't use up
// anyone's allowance (invite SMS: see lib/twilio.js's trySendInviteSMS).
// Each quota is `{ key, max, reason }` plus either `windowMs` (a rolling
// window ending now) or `utcDay: true` (the current UTC calendar day).
//
// Resolves to `{ allowed: true }` after recording one use against every
// quota, or `{ allowed: false, reason }` naming the first quota that was
// already full, in which case nothing is recorded. Rejects if the database
// fails; callers decide whether that blocks the action.
//
// Uses the same RateLimitBucket table, with one row per recorded use
// (`windowStart` is the time of use rather than an aligned window start),
// so the sweep above cleans these rows up too. Per-key advisory locks,
// taken in sorted order so two callers can't deadlock, make the
// count-then-insert atomic. Calls that share a key (such as a global cap)
// therefore run one at a time.
async function reserveQuotas(quotas) {
  ensureSweepStarted();
  const now = new Date();
  const startOfUTCDay = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const endOfUTCDay = new Date(startOfUTCDay.getTime() + 24 * 60 * 60 * 1000);
  const resolved = quotas.map((quota) => ({
    ...quota,
    since: quota.utcDay ? startOfUTCDay : new Date(now.getTime() - quota.windowMs),
    expiresAt: quota.utcDay ? endOfUTCDay : new Date(now.getTime() + quota.windowMs),
  }));
  const lockOrder = [...new Set(resolved.map((quota) => quota.key))].sort();

  return prisma.$transaction(async (tx) => {
    for (const key of lockOrder) {
      // eslint-disable-next-line no-await-in-loop
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 0))`;
    }
    for (const quota of resolved) {
      // eslint-disable-next-line no-await-in-loop
      const rows = await tx.$queryRaw`
        SELECT COALESCE(SUM("count"), 0)::int AS "used"
        FROM "RateLimitBucket"
        WHERE "key" = ${quota.key} AND "windowStart" >= ${quota.since}`;
      if (Number(rows[0].used) >= quota.max) {
        return { allowed: false, reason: quota.reason };
      }
    }
    for (const quota of resolved) {
      // eslint-disable-next-line no-await-in-loop
      await tx.$executeRaw`
        INSERT INTO "RateLimitBucket" ("key", "windowStart", "count", "expiresAt")
        VALUES (${quota.key}, ${now}, 1, ${quota.expiresAt})
        ON CONFLICT ("key", "windowStart")
        DO UPDATE SET "count" = "RateLimitBucket"."count" + 1`;
    }
    return { allowed: true };
  // Callers that share a key wait on each other's lock, so allow more than
  // Prisma's defaults (2 s to get a connection, 5 s to finish).
  }, { maxWait: 10_000, timeout: 15_000 });
}

module.exports = { createRateLimiter, sweepExpiredBuckets, reserveQuotas };
