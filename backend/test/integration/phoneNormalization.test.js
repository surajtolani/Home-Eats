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

  const PROFILE = {
    firstName: "Asha",
    lastName: "Rao",
    city: "Boston",
    state: "Massachusetts",
    country: "United States",
    email: "asha@example.com",
  };

  await t.test("Sign In with a number that has no account: no text, no account", async () => {
    await resetDatabase();
    verifySends.length = 0;
    verifyChecks.length = 0;
    const send = await post("/auth/request-code", { phoneNumber: "+117813633306", intent: "signIn" });
    assert.equal(send.status, 404);
    assert.match(send.body.error, /couldn't sign you in.*Create Account/);
    assert.deepEqual(verifySends, []);
    // Even with a valid code, verify-code won't create the account.
    const check = await post("/auth/verify-code", { phoneNumber: "+17813633306", code: "123456", intent: "signIn" });
    assert.equal(check.status, 404);
    assert.equal(await prisma.user.count(), 0);
  });

  await t.test("Sign In with an existing number sends the code and signs in", async () => {
    await resetDatabase();
    verifySends.length = 0;
    const existing = await createTestUser({ phoneNumber: "+17813633306" });
    const send = await post("/auth/request-code", { phoneNumber: "+1 781 363 3306", intent: "signIn" });
    assert.deepEqual(send, { status: 200, body: { ok: true, phoneNumber: "+17813633306" } });
    assert.equal(verifySends.length, 1);
    const check = await post("/auth/verify-code", { phoneNumber: "+17813633306", code: "123456", intent: "signIn" });
    assert.equal(check.status, 200, JSON.stringify(check.body));
    assert.equal(check.body.user.id, existing.id);
  });

  await t.test("a no-account answer doesn't use up the text limits", async () => {
    await resetDatabase();
    verifySends.length = 0;
    const phoneNumber = "+447911123456";
    const signIn = await post("/auth/request-code", { phoneNumber, intent: "signIn" });
    assert.equal(signIn.status, 404);
    // Straight away, as someone tapping Create Account would. The text
    // limit is 1 per minute per number.
    const signUp = await post("/auth/request-code", { phoneNumber, intent: "signUp" });
    assert.deepEqual(signUp, { status: 200, body: { ok: true, phoneNumber } });
    assert.equal(verifySends.length, 1);
  });

  await t.test("Create Account makes a complete account in one step", async () => {
    await resetDatabase();
    const res = await post("/auth/verify-code", {
      phoneNumber: "+91 98765 43210",
      code: "123456",
      intent: "signUp",
      profile: { ...PROFILE, email: "  asha@example.com " },
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.user.profileComplete, true);
    assert.equal(res.body.user.email, "asha@example.com");
    const user = await prisma.user.findUnique({ where: { phoneNumber: "+919876543210" } });
    assert.equal(user.displayName, "Asha Rao");
    assert.equal(user.email, "asha@example.com");
  });

  await t.test("Create Account refuses a number that already has a complete account", async () => {
    await resetDatabase();
    verifySends.length = 0;
    const existing = await createTestUser({ phoneNumber: "+17813633306", ...PROFILE, email: null });
    const send = await post("/auth/request-code", { phoneNumber: "+17813633306", intent: "signUp" });
    assert.deepEqual(send, { status: 409, body: { error: "This number already has an account. Go back and sign in instead." } });
    assert.deepEqual(verifySends, []);
    const check = await post("/auth/verify-code", {
      phoneNumber: "+17813633306", code: "123456", intent: "signUp", profile: { ...PROFILE, firstName: "Someone" },
    });
    assert.equal(check.status, 409);
    const after = await prisma.user.findUnique({ where: { id: existing.id } });
    assert.equal(after.firstName, "Asha");
  });

  await t.test("Create Account finishes an account that never got a profile", async () => {
    await resetDatabase();
    const stray = await createTestUser({ phoneNumber: "+17813633306" });
    const send = await post("/auth/request-code", { phoneNumber: "+17813633306", intent: "signUp" });
    assert.equal(send.status, 200);
    const check = await post("/auth/verify-code", { phoneNumber: "+17813633306", code: "123456", intent: "signUp", profile: PROFILE });
    assert.equal(check.status, 200, JSON.stringify(check.body));
    assert.equal(check.body.user.id, stray.id);
    assert.equal(check.body.user.profileComplete, true);
    assert.equal(await prisma.user.count(), 1);
  });

  await t.test("Create Account with name and email only: saved, city still to pick", async () => {
    await resetDatabase();
    const { city, state, country, ...nameAndEmail } = PROFILE;
    const res = await post("/auth/verify-code", { phoneNumber: "+17813633306", code: "123456", intent: "signUp", profile: nameAndEmail });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.user.profileComplete, false);
    assert.equal(res.body.user.firstName, "Asha");
    assert.equal(res.body.user.email, "asha@example.com");
    assert.equal(res.body.user.city, null);
  });

  await t.test("Create Account needs a name and a valid email", async () => {
    await resetDatabase();
    const base = { phoneNumber: "+17813633306", code: "123456", intent: "signUp" };
    assert.equal((await post("/auth/verify-code", base)).status, 400);
    const { email, ...noEmail } = PROFILE;
    assert.deepEqual(await post("/auth/verify-code", { ...base, profile: noEmail }), {
      status: 400, body: { error: "email is required." },
    });
    assert.deepEqual(await post("/auth/verify-code", { ...base, profile: { ...PROFILE, email: "asha@" } }), {
      status: 400, body: { error: "Enter a valid email address." },
    });
    assert.deepEqual(await post("/auth/verify-code", { ...base, profile: { ...PROFILE, lastName: "  " } }), {
      status: 400, body: { error: "lastName can't be empty." },
    });
    assert.deepEqual(await post("/auth/verify-code", { ...base, profile: { ...PROFILE, city: "  " } }), {
      status: 400, body: { error: "city can't be empty." },
    });
    assert.equal(await prisma.user.count(), 0);
  });

  await t.test("requests without intent (older app builds) behave as before", async () => {
    await resetDatabase();
    const res = await post("/auth/verify-code", { phoneNumber: "+17813633306", code: "123456" });
    assert.equal(res.status, 200);
    assert.equal(res.body.user.profileComplete, false);
    assert.equal(await prisma.user.count(), 1);
    assert.equal((await post("/auth/request-code", { phoneNumber: "+61412345678", intent: "other" })).status, 400);
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
