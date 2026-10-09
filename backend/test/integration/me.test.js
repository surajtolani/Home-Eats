"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  startTestServer,
  signTestToken,
  createTestUser,
  resetDatabase,
} = require("../helpers/server");

test("GET /me", async (t) => {
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(() => server.close());
  await resetDatabase();

  await t.test("401 without a token", async () => {
    const res = await fetch(`${server.baseURL}/me`);
    assert.equal(res.status, 401);
  });

  await t.test("200 with a valid token", async () => {
    const user = await createTestUser();
    const res = await fetch(`${server.baseURL}/me`, {
      headers: { Authorization: `Bearer ${signTestToken(user.id, user.tokenVersion)}` },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.user.id, user.id);
  });

  await t.test("401 when the token's tokenVersion is behind the user's", async () => {
    const user = await createTestUser({ tokenVersion: 1 });
    const res = await fetch(`${server.baseURL}/me`, {
      headers: { Authorization: `Bearer ${signTestToken(user.id, 0)}` },
    });
    assert.equal(res.status, 401);
  });
});
