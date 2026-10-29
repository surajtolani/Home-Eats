"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { setTimeout: sleep } = require("node:timers/promises");
const {
  startTestServer,
  signTestToken,
  createTestUser,
  resetDatabase,
} = require("../helpers/server");

const DAY_MS = 24 * 60 * 60 * 1000;

test("invite SMS safeguards", async (t) => {
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  // Loaded after startTestServer so these share the app's module instances.
  const twilio = require("../../lib/twilio");
  const { reserveQuotas } = require("../../lib/rateLimit");
  const { phoneLogKey } = require("../../lib/redact");
  const { prisma } = require("../../lib/prisma");

  const sent = [];
  twilio.__setClientForTests({ messages: { create: async (message) => sent.push(message) } });
  const savedEnv = {};
  const SETTINGS = [
    "INVITE_SMS_SENDER_DAILY_MAX",
    "INVITE_SMS_SENDER_MONTHLY_MAX",
    "INVITE_SMS_DAILY_GLOBAL_MAX",
    "INVITE_SMS_ALLOWED_COUNTRY_CODES",
  ];
  for (const name of ["TWILIO_SMS_FROM_NUMBER", "APP_DOWNLOAD_URL", ...SETTINGS]) {
    savedEnv[name] = process.env[name];
    delete process.env[name];
  }
  process.env.TWILIO_SMS_FROM_NUMBER = "+15550000000";
  t.after(async () => {
    twilio.__setClientForTests(null);
    for (const [name, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await server.close();
  });

  // Every invite SMS attempt ends with exactly one
  // "[invite-sms] sent|skipped|failed" log line, written after the route has already responded. Capturing those
  // lets each test wait until the attempts it triggered have finished.
  const inviteLog = [];
  for (const level of ["log", "error"]) {
    const original = console[level];
    t.mock.method(console, level, (...args) => {
      const first = String(args[0]);
      if (/^\[invite-sms\] (sent|skipped|failed) /.test(first)) {
        inviteLog.push({ level, line: first });
      } else if (level === "error" && first !== "Invite SMS send failed") {
        original(...args);
      }
    });
  }
  async function waitForAttempts(count) {
    const deadline = Date.now() + 5000;
    while (inviteLog.length < count) {
      if (Date.now() > deadline) throw new Error(`Timed out waiting for ${count} invite SMS attempts; saw ${inviteLog.length}`);
      // eslint-disable-next-line no-await-in-loop
      await sleep(10);
    }
  }

  async function freshState() {
    await resetDatabase();
    sent.length = 0;
    inviteLog.length = 0;
    for (const name of SETTINGS) delete process.env[name];
  }

  async function newUser(displayName = "Sam") {
    const user = await createTestUser({ displayName });
    return { user, auth: { Authorization: `Bearer ${signTestToken(user.id, user.tokenVersion)}` } };
  }

  async function post(path, auth, body) {
    const res = await fetch(`${server.baseURL}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...auth },
      body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json() };
  }

  let nextNumber = 0;
  function newUSNumber() {
    nextNumber += 1;
    return `+1415555${String(1000 + nextNumber).padStart(4, "0")}`;
  }

  await t.test("friend invite text is the fixed template with a sanitized name", async () => {
    await freshState();
    const { auth } = await newUser("Bob visit evil.com/x");
    const to = newUSNumber();
    const res = await post("/friends/request", auth, { phoneNumber: to });
    assert.equal(res.status, 201);
    await waitForAttempts(1);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].to, to);
    assert.equal(sent[0].from, "+15550000000");
    assert.equal(sent[0].body, "Bob visit evilcomx invited you to Home Eats, a family meal-planning app. Reply STOP to opt out.");
  });

  await t.test("group invite text never includes the group name", async () => {
    await freshState();
    const { auth } = await newUser("Sam");
    const group = await post("/groups", auth, { name: "Your bank account is locked, verify at evil.example" });
    assert.equal(group.status, 201);
    const groupId = group.body.group.id;
    const res = await post(`/groups/${groupId}/invite`, auth, { phoneNumber: newUSNumber() });
    assert.equal(res.status, 201);
    await waitForAttempts(1);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].body, "Sam invited you to plan meals together on Home Eats. Reply STOP to opt out.");
  });

  async function seedSenderMonthHistory(userId, count) {
    // Earlier texts spread over the last 2 to 29 days (outside the 24-hour cap).
    const now = Date.now();
    await prisma.rateLimitBucket.createMany({
      data: Array.from({ length: count }, (_, i) => ({
        key: `invite-sms:sender-month:${userId}`,
        windowStart: new Date(now - 2 * DAY_MS - Math.floor((i * 27 * DAY_MS) / count)),
        count: 1,
        expiresAt: new Date(now + DAY_MS),
      })),
    });
  }

  await t.test("by default one sender gets 75 invite texts per 24 hours; the 76th is skipped", async () => {
    await freshState();
    const { user, auth } = await newUser();
    for (let i = 0; i < 76; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const res = await post("/friends/request", auth, { phoneNumber: newUSNumber() });
      assert.equal(res.status, 201);
    }
    await waitForAttempts(76);
    assert.equal(sent.length, 75);
    assert.equal(inviteLog.filter((entry) => / reason=sender-day-limit /.test(entry.line)).length, 1);
    assert.equal(await prisma.invite.count({ where: { invitingUserId: user.id } }), 76);
  });

  await t.test("by default one sender gets 300 invite texts per 30 days", async () => {
    await freshState();
    const under = await newUser();
    await seedSenderMonthHistory(under.user.id, 299);
    await post("/friends/request", under.auth, { phoneNumber: newUSNumber() });
    await waitForAttempts(1);
    assert.equal(sent.length, 1);

    const over = await newUser();
    await seedSenderMonthHistory(over.user.id, 300);
    await post("/friends/request", over.auth, { phoneNumber: newUSNumber() });
    await waitForAttempts(2);
    assert.equal(sent.length, 1);
    assert.match(inviteLog[1].line, /^\[invite-sms\] skipped reason=sender-month-limit /);
  });

  await t.test("INVITE_SMS_SENDER_DAILY_MAX changes the daily cap; response and Invite unchanged when skipped", async () => {
    await freshState();
    process.env.INVITE_SMS_SENDER_DAILY_MAX = "5";
    const { user, auth } = await newUser();
    const responses = [];
    for (let i = 0; i < 6; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      responses.push(await post("/friends/request", auth, { phoneNumber: newUSNumber() }));
      // eslint-disable-next-line no-await-in-loop
      await waitForAttempts(i + 1);
    }
    for (const res of responses) {
      assert.deepEqual(res, { status: 201, body: { status: "requested" } });
    }
    assert.equal(sent.length, 5);
    assert.match(inviteLog[5].line, /^\[invite-sms\] skipped reason=sender-day-limit /);
    assert.equal(await prisma.invite.count({ where: { invitingUserId: user.id } }), 6);
  });

  await t.test("a second invite text to the same number within 7 days is skipped, across senders", async () => {
    await freshState();
    const a = await newUser("Alice");
    const b = await newUser("Bea");
    const to = newUSNumber();
    assert.equal((await post("/friends/request", a.auth, { phoneNumber: to })).status, 201);
    await waitForAttempts(1);
    const second = await post("/friends/request", b.auth, { phoneNumber: to });
    assert.deepEqual(second, { status: 201, body: { status: "requested" } });
    await waitForAttempts(2);
    assert.equal(sent.length, 1);
    assert.match(inviteLog[1].line, /^\[invite-sms\] skipped reason=recipient-limit /);
    assert.equal(await prisma.invite.count({ where: { invitedPhoneNumber: to } }), 2);
  });

  await t.test("by default invite texts can go to any country", async () => {
    await freshState();
    const { auth } = await newUser();
    for (const to of ["+442071838750", "+919876543210", "+61412345678"]) {
      // eslint-disable-next-line no-await-in-loop
      await post("/friends/request", auth, { phoneNumber: to });
    }
    await waitForAttempts(3);
    assert.deepEqual(sent.map((m) => m.to), ["+442071838750", "+919876543210", "+61412345678"]);
  });

  await t.test("numbers outside a configured country allow-list are skipped", async () => {
    await freshState();
    process.env.INVITE_SMS_ALLOWED_COUNTRY_CODES = "1";
    const { user, auth } = await newUser();
    const res = await post("/friends/request", auth, { phoneNumber: "+442071838750" });
    assert.deepEqual(res, { status: 201, body: { status: "requested" } });
    await waitForAttempts(1);
    assert.equal(sent.length, 0);
    assert.match(inviteLog[0].line, /^\[invite-sms\] skipped reason=country-not-allowed /);
    assert.equal(await prisma.invite.count({ where: { invitingUserId: user.id } }), 1);

    process.env.INVITE_SMS_ALLOWED_COUNTRY_CODES = "+1, 44";
    await post("/friends/request", auth, { phoneNumber: "+442071838751" });
    await waitForAttempts(2);
    assert.equal(sent.length, 1);
  });

  await t.test("a blank country allow-list means the default (every country), not 'nowhere'", async () => {
    await freshState();
    process.env.INVITE_SMS_ALLOWED_COUNTRY_CODES = "  ";
    const { auth } = await newUser();
    await post("/friends/request", auth, { phoneNumber: "+442071838752" });
    await waitForAttempts(1);
    assert.equal(sent.length, 1);
  });

  await t.test("by default the whole app sends 500 invite texts per UTC day", async () => {
    // One row standing for earlier texts today. Its time is halfway between
    // UTC midnight and now, so it's always inside today's window.
    async function seedGlobalToday(count) {
      const now = Date.now();
      const startOfUTCDay = now - (now % DAY_MS);
      await prisma.rateLimitBucket.create({
        data: {
          key: "invite-sms:global:all",
          windowStart: new Date(startOfUTCDay + Math.floor((now - startOfUTCDay) / 2)),
          count,
          expiresAt: new Date(startOfUTCDay + DAY_MS),
        },
      });
    }
    await freshState();
    await seedGlobalToday(499);
    const { auth } = await newUser();
    await post("/friends/request", auth, { phoneNumber: newUSNumber() });
    await waitForAttempts(1);
    assert.equal(sent.length, 1);
    // That was the 500th; the next one is skipped.
    await post("/friends/request", auth, { phoneNumber: newUSNumber() });
    await waitForAttempts(2);
    assert.equal(sent.length, 1);
    assert.match(inviteLog[1].line, /^\[invite-sms\] skipped reason=global-daily-limit /);
  });

  await t.test("INVITE_SMS_DAILY_GLOBAL_MAX stops sends across all senders and logs an error", async () => {
    await freshState();
    process.env.INVITE_SMS_DAILY_GLOBAL_MAX = "2";
    for (let i = 0; i < 3; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const { auth } = await newUser();
      // eslint-disable-next-line no-await-in-loop
      await post("/friends/request", auth, { phoneNumber: newUSNumber() });
      // eslint-disable-next-line no-await-in-loop
      await waitForAttempts(i + 1);
    }
    assert.equal(sent.length, 2);
    assert.equal(inviteLog[2].level, "error");
    assert.match(inviteLog[2].line, /^\[invite-sms\] skipped reason=global-daily-limit /);
  });

  await t.test("INVITE_SMS_SENDER_MONTHLY_MAX changes the 30-day cap, which counts texts older than 24 hours", async () => {
    await freshState();
    process.env.INVITE_SMS_SENDER_MONTHLY_MAX = "20";
    const { user, auth } = await newUser();
    await seedSenderMonthHistory(user.id, 20);
    await post("/friends/request", auth, { phoneNumber: newUSNumber() });
    await waitForAttempts(1);
    assert.equal(sent.length, 0);
    assert.match(inviteLog[0].line, /^\[invite-sms\] skipped reason=sender-month-limit /);
  });

  await t.test("windows are rolling: a text 8 days ago doesn't block, one 6 days ago does", async () => {
    await freshState();
    const { auth } = await newUser();
    const oldTo = newUSNumber();
    const recentTo = newUSNumber();
    const now = Date.now();
    for (const [to, daysAgo] of [[oldTo, 8], [recentTo, 6]]) {
      // eslint-disable-next-line no-await-in-loop
      await prisma.rateLimitBucket.create({
        data: {
          key: `invite-sms:recipient:${phoneLogKey(to)}`,
          windowStart: new Date(now - daysAgo * DAY_MS),
          count: 1,
          expiresAt: new Date(now + DAY_MS),
        },
      });
    }
    await post("/friends/request", auth, { phoneNumber: oldTo });
    await waitForAttempts(1);
    await post("/friends/request", auth, { phoneNumber: recentTo });
    await waitForAttempts(2);
    assert.deepEqual(sent.map((m) => m.to), [oldTo]);
    assert.match(inviteLog[1].line, /reason=recipient-limit /);
  });

  await t.test("a skipped text uses up no one's allowance", async () => {
    await freshState();
    process.env.INVITE_SMS_SENDER_DAILY_MAX = "5";
    const busy = await newUser("Busy");
    for (let i = 0; i < 5; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      await post("/friends/request", busy.auth, { phoneNumber: newUSNumber() });
      // eslint-disable-next-line no-await-in-loop
      await waitForAttempts(i + 1);
    }
    const to = newUSNumber();
    // Blocked by the sender's own daily cap...
    await post("/friends/request", busy.auth, { phoneNumber: to });
    await waitForAttempts(6);
    assert.match(inviteLog[5].line, /reason=sender-day-limit /);
    // ...so the recipient's 7-day allowance is still unused.
    const other = await newUser("Other");
    await post("/friends/request", other.auth, { phoneNumber: to });
    await waitForAttempts(7);
    assert.equal(sent.length, 6);
    assert.equal(sent[5].to, to);
  });

  await t.test("logs show the recipient only redacted", async () => {
    await freshState();
    const { auth } = await newUser();
    const to = newUSNumber();
    await post("/friends/request", auth, { phoneNumber: to });
    await waitForAttempts(1);
    assert.ok(!inviteLog[0].line.includes(to.slice(1, 8)), inviteLog[0].line);
    assert.ok(inviteLog[0].line.includes(`to=+1•••••${to.slice(-4)} toKey=`), inviteLog[0].line);
  });

  await t.test("a message Twilio rejects is logged as a failure, not as sent", async () => {
    await freshState();
    const { auth } = await newUser();
    twilio.__setClientForTests({
      messages: {
        create: async () => {
          throw new Error("Twilio rejected the message");
        },
      },
    });
    try {
      const res = await post("/friends/request", auth, { phoneNumber: newUSNumber() });
      assert.deepEqual(res, { status: 201, body: { status: "requested" } });
      await waitForAttempts(1);
    } finally {
      twilio.__setClientForTests({ messages: { create: async (message) => sent.push(message) } });
    }
    assert.equal(inviteLog[0].level, "error");
    assert.match(inviteLog[0].line, /^\[invite-sms\] failed reason=twilio-error /);
  });

  await t.test("reserveQuotas is atomic under concurrency", async () => {
    await freshState();
    const results = await Promise.all(
      Array.from({ length: 10 }, () =>
        reserveQuotas([{ reason: "test", key: "test:concurrent", windowMs: DAY_MS, max: 3 }])
      )
    );
    assert.equal(results.filter((r) => r.allowed).length, 3);
    assert.equal(results.filter((r) => !r.allowed).length, 7);
  });
});
