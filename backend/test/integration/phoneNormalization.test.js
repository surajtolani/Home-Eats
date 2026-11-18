"use strict";

// Every route that takes a phone number stores and looks it up in canonical
// E.164 form, however it was typed or autofilled. Twilio is replaced with a
// fake before the app loads (this file runs in its own process).
const test = require("node:test");
const assert = require("node:assert/strict");

const verifySends = [];
const verifyChecks = [];
require.cache[require.resolve("twilio")] = {
  id: require.resolve("twilio"),
  filename: require.resolve("twilio"),
  loaded: true,
  exports: () => ({
    verify: {
      v2: {
        services: () => ({
          verifications: { create: async (params) => verifySends.push(params) },
          verificationChecks: {
            create: async (params) => {
              verifyChecks.push(params);
              return { status: params.code === "123456" ? "approved" : "pending" };
            },
          },
        }),
      },
    },
    messages: { create: async () => ({}) },
  }),
};

const { startTestServer, signTestToken, createTestUser, resetDatabase } = require("../helpers/server");
const { PHONE_ERROR } = require("../../lib/phone");

test("phone numbers are normalized on every route", async (t) => {
  const savedEnv = {};
  for (const name of ["TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_VERIFY_SERVICE_SID", "TWILIO_SMS_FROM_NUMBER"]) {
    savedEnv[name] = process.env[name];
  }
  process.env.TWILIO_ACCOUNT_SID = "ACtest";
  process.env.TWILIO_AUTH_TOKEN = "test";
  process.env.TWILIO_VERIFY_SERVICE_SID = "VAtest";
  delete process.env.TWILIO_SMS_FROM_NUMBER;

  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(async () => {
    for (const [name, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await server.close();
  });
  t.mock.method(console, "log", () => {});
  const { prisma } = require("../../lib/prisma");

  const post = async (path, body, token) => {
    const headers = { "Content-Type": "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    const res = await fetch(`${server.baseURL}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
    return { status: res.status, body: await res.json().catch(() => null) };
  };

  await t.test("request-code sends the code to the canonical number", async () => {
    await resetDatabase();
    verifySends.length = 0;
    const res = await post("/auth/request-code", { phoneNumber: "+1 (781) 363-3306" });
    assert.deepEqual(res, { status: 200, body: { ok: true, phoneNumber: "+17813633306" } });
    assert.deepEqual(verifySends, [{ to: "+17813633306", channel: "sms" }]);
  });

  await t.test("a doubled country code signs in to the existing account", async () => {
    await resetDatabase();
    verifyChecks.length = 0;
    const existing = await createTestUser({ phoneNumber: "+17813633306" });
    const res = await post("/auth/verify-code", { phoneNumber: "+117813633306", code: "123456" });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.user.id, existing.id);
    assert.deepEqual(verifyChecks, [{ to: "+17813633306", code: "123456" }]);
    assert.equal(await prisma.user.count(), 1);
  });

  await t.test("a new user is stored under the canonical number", async () => {
    await resetDatabase();
    const res = await post("/auth/verify-code", { phoneNumber: "+44 07911 123456", code: "123456" });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    const users = await prisma.user.findMany({ select: { phoneNumber: true } });
    assert.deepEqual(users, [{ phoneNumber: "+447911123456" }]);
  });

  await t.test("an invalid number gets a clear 400 and never reaches Twilio", async () => {
    await resetDatabase();
    verifySends.length = 0;
    verifyChecks.length = 0;
    const send = await post("/auth/request-code", { phoneNumber: "+1234" });
    assert.deepEqual(send, { status: 400, body: { error: PHONE_ERROR } });
    const check = await post("/auth/verify-code", { phoneNumber: "7813633306", code: "123456" });
    assert.deepEqual(check, { status: 400, body: { error: PHONE_ERROR } });
    assert.deepEqual(verifySends, []);
    assert.deepEqual(verifyChecks, []);
  });

  await t.test("friend requests match an existing user however the number is written", async () => {
    await resetDatabase();
    const me = await createTestUser({ displayName: "Me" });
    const them = await createTestUser({ phoneNumber: "+17813633306" });
    const res = await post("/friends/request", { phoneNumber: "+1 1 781 363 3306" }, signTestToken(me.id, me.tokenVersion));
    assert.equal(res.status, 201, JSON.stringify(res.body));
    const friendship = await prisma.friendship.findFirst({ where: { requesterId: me.id } });
    assert.equal(friendship?.recipientId, them.id);
    assert.equal(await prisma.invite.count(), 0);
  });

  await t.test("friend invites to a non-user store the canonical number", async () => {
    await resetDatabase();
    const me = await createTestUser({ displayName: "Me" });
    const res = await post("/friends/request", { phoneNumber: "+91 98765 43210" }, signTestToken(me.id, me.tokenVersion));
    assert.equal(res.status, 201, JSON.stringify(res.body));
    const invites = await prisma.invite.findMany({ select: { invitedPhoneNumber: true } });
    assert.deepEqual(invites, [{ invitedPhoneNumber: "+919876543210" }]);
  });

  await t.test("group invites store the canonical number", async () => {
    await resetDatabase();
    const me = await createTestUser({ displayName: "Me" });
    const token = signTestToken(me.id, me.tokenVersion);
    const group = await post("/groups", { name: "Family" }, token);
    assert.equal(group.status, 201, JSON.stringify(group.body));
    const groupId = group.body.id ?? group.body.group?.id;
    assert.ok(groupId, JSON.stringify(group.body));
    const res = await post(`/groups/${groupId}/invite`, { phoneNumber: "+61 412 345 678" }, token);
    assert.equal(res.status, 201, JSON.stringify(res.body));
    const invites = await prisma.invite.findMany({ select: { invitedPhoneNumber: true } });
    assert.deepEqual(invites, [{ invitedPhoneNumber: "+61412345678" }]);
  });
});
