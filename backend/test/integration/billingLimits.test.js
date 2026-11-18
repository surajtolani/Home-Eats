"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { startTestServer, signTestToken, createTestUser, resetDatabase } = require("../helpers/server");

const DAY_MS = 24 * 60 * 60 * 1000;

test("billing safeguards", async (t) => {
  // No paid API is configured in tests, so a request that got past input
  // validation would reach the route and fail with a "Server is missing ..."
  // 500. A 400 therefore proves validation ran first.
  for (const name of ["ANTHROPIC_API_KEY", "GOOGLE_PLACES_API_KEY", "GOOGLE_CUSTOM_SEARCH_API_KEY", "GOOGLE_CUSTOM_SEARCH_CX", "AI_DAILY_USER_MAX"]) {
    delete process.env[name];
  }
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(() => server.close());
  const { prisma } = require("../../lib/prisma");
  // Routes log their own errors (e.g. a missing API key); keep output clean.
  t.mock.method(console, "error", () => {});

  async function newAuth() {
    const user = await createTestUser({ displayName: "Sam" });
    return { user, headers: { Authorization: `Bearer ${signTestToken(user.id, user.tokenVersion)}` } };
  }

  async function call(method, path, { headers = {}, body, rawBody } = {}) {
    const res = await fetch(`${server.baseURL}${path}`, {
      method,
      headers: { ...(body !== undefined || rawBody !== undefined ? { "Content-Type": "application/json" } : {}), ...headers },
      body: rawBody !== undefined ? rawBody : body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch (error) {
      // Not JSON (e.g. an image); leave json null.
    }
    return { status: res.status, json };
  }

  // Seeds a fixed-window limiter bucket (lib/rateLimit.js createRateLimiter)
  // so the current window already holds `count` hits.
  async function seedBucket(key, count) {
    const now = Date.now();
    const windowStart = new Date(Math.floor(now / DAY_MS) * DAY_MS);
    await prisma.rateLimitBucket.create({
      data: { key, windowStart, count, expiresAt: new Date(windowStart.getTime() + DAY_MS) },
    });
  }

  await t.test("image routes require a signed-in user", async () => {
    await resetDatabase();
    const photo = await call("GET", "/restaurants/photo?name=places/abc/photos/def");
    assert.equal(photo.status, 401);
    const proxy = await call("GET", "/recipes/image-proxy?url=https://example.com/x.png");
    assert.equal(proxy.status, 401);

    const { headers } = await newAuth();
    // Signed in, the request gets past auth and the limiter to the route's
    // own checks.
    const badName = await call("GET", "/restaurants/photo?name=not-a-photo-name", { headers });
    assert.deepEqual(badName, { status: 400, json: { error: "Invalid 'name' format." } });
    const noName = await call("GET", "/restaurants/photo", { headers });
    assert.deepEqual(noName, { status: 400, json: { error: "Missing required query param 'name'." } });
    const noURL = await call("GET", "/recipes/image-proxy", { headers });
    assert.equal(noURL.status, 400);
  });

  await t.test("oversized AI input is a 400 before any paid call", async () => {
    await resetDatabase();
    const { headers } = await newAuth();
    const cases = [
      ["/recipes/extract", { notesText: "x".repeat(10001) }, "'notesText' can't be longer than 10,000 characters."],
      ["/recipes/extract", {}, "Provide imageBase64 and/or notesText."],
      ["/recipes/extract", { notesText: "   " }, "Provide imageBase64 and/or notesText."],
      ["/recipes/extract", { imageBase64: "not base64!" }, "'imageBase64' must be valid base64."],
      ["/recipes/extract", { imageBase64: "QUJD", mediaType: "image/svg+xml" }, "'mediaType' must be one of image/jpeg, image/png, image/webp, image/gif."],
      ["/recipes/recommend", { ingredients: Array(41).fill("egg") }, "List at most 40 ingredients."],
      ["/recipes/recommend", { ingredients: ["x".repeat(81)] }, "Each ingredient can be at most 80 characters."],
      ["/recipes/recommend", { ingredients: [42] }, "Each ingredient must be text."],
      ["/recipes/recommend", { ingredients: "egg" }, "'ingredients' must be a list."],
      ["/recipes/recommend", { excludeTitles: Array(41).fill("Soup") }, "Send at most 40 titles to exclude."],
      ["/recipes/recommend", { excludeTitles: ["x".repeat(201)] }, "Each title can be at most 200 characters."],
      ["/restaurants/search-natural", { query: "x".repeat(301) }, "'query' can't be longer than 300 characters."],
      ["/restaurants/search-natural", {}, "Missing required field 'query'."],
      ["/restaurants/search-natural", { query: "pizza", lat: 91, lng: 0 }, "'lat' must be between -90 and 90."],
      ["/restaurants/search-natural", { query: "pizza", lat: 0, lng: -181 }, "'lng' must be between -180 and 180."],
      ["/restaurants/search-natural", { query: "pizza", fallbackLocationText: "x".repeat(201) }, "'fallbackLocationText' can't be longer than 200 characters."],
    ];
    for (const [path, body, message] of cases) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", path, { headers, body });
      assert.deepEqual(res, { status: 400, json: { error: message } }, `${path} ${JSON.stringify(body).slice(0, 60)}`);
    }
    for (const path of ["/restaurants/search", "/cities/search", "/recipes/web-search"]) {
      // eslint-disable-next-line no-await-in-loop
      const tooLong = await call("GET", `${path}?q=${"x".repeat(201)}`, { headers });
      assert.deepEqual(tooLong, { status: 400, json: { error: "'q' can't be longer than 200 characters." } }, path);
      // eslint-disable-next-line no-await-in-loop
      const missing = await call("GET", path, { headers });
      assert.deepEqual(missing, { status: 400, json: { error: "Missing required query param 'q'." } }, path);
    }
  });

  await t.test("valid AI input still reaches the route", async () => {
    await resetDatabase();
    const { headers } = await newAuth();
    for (const [path, body] of [
      ["/recipes/extract", { notesText: "2 eggs, scramble" }],
      ["/recipes/extract", { imageBase64: "QUJD", mediaType: "image/png" }],
      ["/recipes/recommend", { ingredients: ["egg"], excludeTitles: ["Soup"] }],
      ["/recipes/recommend", {}],
      // Blank items (a trailing comma, a stray newline) are dropped, not rejected.
      ["/recipes/recommend", { ingredients: ["chicken", "rice", "\n", ""], excludeTitles: [" "] }],
      // ...and don't count toward the 40-item limit.
      ["/recipes/recommend", { ingredients: [...Array(40).fill("egg"), "", " ", "\n"] }],
    ]) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", path, { headers, body });
      assert.deepEqual(res, { status: 500, json: { error: "Server is missing ANTHROPIC_API_KEY." } }, path);
    }
    const natural = await call("POST", "/restaurants/search-natural", { headers, body: { query: "pizza", lat: 40.7, lng: -74 } });
    assert.deepEqual(natural, { status: 500, json: { error: "Server is missing GOOGLE_PLACES_API_KEY." } });
  });

  await t.test("malformed photo requests don't use up the photo limits", async () => {
    await resetDatabase();
    const { user, headers } = await newAuth();
    await seedBucket(`restaurants-photo-daily:user:${user.id}`, 999);
    for (let i = 0; i < 5; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("GET", "/restaurants/photo?name=bad", { headers });
      assert.equal(res.status, 400);
    }
    // One left in the daily cap: a valid request still gets through to the
    // route (which then fails on the missing Google key).
    const valid = await call("GET", "/restaurants/photo?name=places/a/photos/b", { headers });
    assert.equal(valid.status, 500);
  });

  await t.test("malformed JSON is a 400, not a server error", async () => {
    const { headers } = await newAuth();
    const res = await call("PATCH", "/me", { headers, rawBody: "{not json" });
    assert.deepEqual(res, { status: 400, json: { error: "Invalid request body." } });
  });

  await t.test("invalid requests don't use up the hourly limit", async () => {
    await resetDatabase();
    const { headers } = await newAuth();
    // The hourly extract limit is 20.
    for (let i = 0; i < 25; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", "/recipes/extract", { headers, body: {} });
      assert.equal(res.status, 400);
    }
    const valid = await call("POST", "/recipes/extract", { headers, body: { notesText: "eggs" } });
    assert.equal(valid.status, 500); // reached the route: not rate-limited
  });

  const AI_REQUESTS = [
    ["/recipes/extract", { notesText: "eggs" }],
    ["/recipes/recommend", {}],
    ["/restaurants/search-natural", { query: "pizza" }],
  ];
  const AI_DAILY_MESSAGE = "You've reached today's limit for AI features. Please try again tomorrow.";

  await t.test("each user gets 40 AI requests per day, shared across the three AI routes", async () => {
    await resetDatabase();
    // Days are UTC calendar days; don't straddle midnight.
    const msToMidnight = DAY_MS - (Date.now() % DAY_MS);
    if (msToMidnight < 30_000) await new Promise((resolve) => setTimeout(resolve, msToMidnight + 100));
    const { headers } = await newAuth();
    // 40 requests rotating through the three routes (14/13/13, each under
    // its own hourly limit). Each reaches the route, which then fails on
    // the missing API key.
    for (let i = 0; i < 40; i += 1) {
      const [path, body] = AI_REQUESTS[i % 3];
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", path, { headers, body });
      assert.equal(res.status, 500, `request ${i + 1} (${path})`);
    }
    // The 41st, on any of the three routes, is over the shared allowance.
    for (const [path, body] of AI_REQUESTS) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", path, { headers, body });
      assert.deepEqual(res, { status: 429, json: { error: AI_DAILY_MESSAGE } }, path);
    }
    // Non-AI paid routes don't count toward it.
    const search = await call("GET", "/restaurants/search?q=pizza", { headers });
    assert.equal(search.status, 500);
  });

  await t.test("one user's AI usage never blocks another user (no deployment-wide cap)", async () => {
    await resetDatabase();
    const heavy = await newAuth();
    await seedBucket(`ai-daily:user:${heavy.user.id}`, 40);
    const blocked = await call("POST", "/recipes/recommend", { headers: heavy.headers, body: {} });
    assert.equal(blocked.status, 429);
    const other = await newAuth();
    for (const [path, body] of AI_REQUESTS) {
      // eslint-disable-next-line no-await-in-loop
      const res = await call("POST", path, { headers: other.headers, body });
      assert.equal(res.status, 500, path);
    }
  });

  await t.test("each user gets 1000 restaurant photos per day", async () => {
    await resetDatabase();
    const { user, headers } = await newAuth();
    await seedBucket(`restaurants-photo-daily:user:${user.id}`, 1000);
    const res = await call("GET", "/restaurants/photo?name=places/a/photos/b", { headers });
    assert.deepEqual(res, {
      status: 429,
      json: { error: "You've reached today's limit for this feature. Please try again tomorrow." },
    });
  });

  await t.test("body size limits: 100 KB by default, 8 MB for photo routes", async () => {
    await resetDatabase();
    const { headers } = await newAuth();
    const big = await call("PATCH", "/me", { headers, rawBody: JSON.stringify({ displayName: "x".repeat(200 * 1024) }) });
    assert.deepEqual(big, { status: 413, json: { error: "Request too large." } });

    // About 1 MB of base64 photo is accepted by /recipes/extract...
    const photo = "A".repeat(1024 * 1024);
    const extract = await call("POST", "/recipes/extract", { headers, body: { imageBase64: photo } });
    assert.deepEqual(extract, { status: 500, json: { error: "Server is missing ANTHROPIC_API_KEY." } });
    // ...and by /recipe-library (it reaches the route's own validation).
    const library = await call("POST", "/recipe-library", { headers, body: { title: "", photoBase64: photo } });
    assert.equal(library.status, 400);
    assert.notEqual(library.json?.error, "Request too large.");

    // Over 8 MB is rejected on the photo routes too.
    const huge = await call("POST", "/recipes/extract", { headers, rawBody: JSON.stringify({ imageBase64: "A".repeat(9 * 1024 * 1024) }) });
    assert.deepEqual(huge, { status: 413, json: { error: "Request too large." } });
  });
});
