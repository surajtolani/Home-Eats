"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { startTestServer, signTestToken, createTestUser, resetDatabase } = require("../helpers/server");

test("sign-out and sign-out-all", async (t) => {
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(() => server.close());
  const { prisma } = require("../../lib/prisma");

  async function call(method, path, { token, body } = {}) {
    const headers = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(`${server.baseURL}${path}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    return { status: res.status, text };
  }

  async function newUserWithDevices(...deviceTokens) {
    const user = await createTestUser({ displayName: "Sam" });
    for (const token of deviceTokens) {
      // eslint-disable-next-line no-await-in-loop
      await prisma.deviceToken.create({ data: { token, userId: user.id } });
    }
    return { user, token: signTestToken(user.id, user.tokenVersion) };
  }

  const tokensOf = async (userId) =>
    (await prisma.deviceToken.findMany({ where: { userId }, select: { token: true }, orderBy: { token: "asc" } })).map(
      (row) => row.token
    );

  await t.test("both routes require a signed-in user", async () => {
    await resetDatabase();
    assert.equal((await call("POST", "/auth/sign-out", { body: {} })).status, 401);
    assert.equal((await call("POST", "/auth/sign-out-all")).status, 401);
  });

  await t.test("sign-out removes only this device's push registration", async () => {
    await resetDatabase();
    const me = await newUserWithDevices("phone-a", "phone-b");
    const res = await call("POST", "/auth/sign-out", { token: me.token, body: { deviceToken: "phone-a" } });
    assert.deepEqual(res, { status: 204, text: "" });
    assert.deepEqual(await tokensOf(me.user.id), ["phone-b"]);
    // The account's own token still works: plain sign-out isn't revocation.
    assert.equal((await call("GET", "/me", { token: me.token })).status, 200);
  });

  await t.test("sign-out can't delete someone else's device token", async () => {
    await resetDatabase();
    const me = await newUserWithDevices("my-phone");
    const other = await newUserWithDevices("their-phone");
    const res = await call("POST", "/auth/sign-out", { token: me.token, body: { deviceToken: "their-phone" } });
    assert.equal(res.status, 204);
    assert.deepEqual(await tokensOf(other.user.id), ["their-phone"]);
    assert.deepEqual(await tokensOf(me.user.id), ["my-phone"]);
  });

  await t.test("sign-out returns 204 with no device token or an unknown one", async () => {
    await resetDatabase();
    const me = await newUserWithDevices("my-phone");
    assert.equal((await call("POST", "/auth/sign-out", { token: me.token })).status, 204);
    assert.equal((await call("POST", "/auth/sign-out", { token: me.token, body: {} })).status, 204);
    assert.equal((await call("POST", "/auth/sign-out", { token: me.token, body: { deviceToken: "nope" } })).status, 204);
    assert.deepEqual(await tokensOf(me.user.id), ["my-phone"]);
  });

  await t.test("sign-out rejects a malformed device token", async () => {
    await resetDatabase();
    const me = await newUserWithDevices();
    assert.equal((await call("POST", "/auth/sign-out", { token: me.token, body: { deviceToken: "x".repeat(501) } })).status, 400);
    assert.equal((await call("POST", "/auth/sign-out", { token: me.token, body: { deviceToken: 42 } })).status, 400);
  });

  await t.test("sign-out-all revokes every token and removes every device", async () => {
    await resetDatabase();
    const me = await newUserWithDevices("phone-a", "phone-b");
    const other = await newUserWithDevices("their-phone");
    // A second token for the same account, as if signed in on another phone.
    const secondToken = signTestToken(me.user.id, me.user.tokenVersion);

    const res = await call("POST", "/auth/sign-out-all", { token: me.token });
    assert.deepEqual(res, { status: 204, text: "" });

    // Every token issued before is now rejected.
    assert.equal((await call("GET", "/me", { token: me.token })).status, 401);
    assert.equal((await call("GET", "/me", { token: secondToken })).status, 401);
    assert.equal((await call("POST", "/auth/sign-out-all", { token: me.token })).status, 401);
    assert.deepEqual(await tokensOf(me.user.id), []);

    // Signing in again (a token carrying the new version) works.
    const refreshed = await prisma.user.findUnique({ where: { id: me.user.id } });
    assert.equal(refreshed.tokenVersion, me.user.tokenVersion + 1);
    assert.equal((await call("GET", "/me", { token: signTestToken(me.user.id, refreshed.tokenVersion) })).status, 200);

    // Other accounts are untouched.
    assert.equal((await call("GET", "/me", { token: other.token })).status, 200);
    assert.deepEqual(await tokensOf(other.user.id), ["their-phone"]);
  });
});
