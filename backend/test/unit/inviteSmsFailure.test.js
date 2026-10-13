// trySendInviteSMS when the cap check can't reach the database: the text is
// skipped (fail closed) and nothing throws.
"use strict";

process.env.DATABASE_URL = "postgresql://test:test@127.0.0.1:1/unreachable";

const test = require("node:test");
const assert = require("node:assert/strict");
const twilio = require("../../lib/twilio");
const { prisma } = require("../../lib/prisma");

test.after(() => prisma.$disconnect());

test("skips the text when the cap check fails", async (t) => {
  const sent = [];
  twilio.__setClientForTests({ messages: { create: async (msg) => sent.push(msg) } });
  t.after(() => twilio.__setClientForTests(null));
  const originalFrom = process.env.TWILIO_SMS_FROM_NUMBER;
  process.env.TWILIO_SMS_FROM_NUMBER = "+15550000000";
  t.after(() => {
    if (originalFrom === undefined) delete process.env.TWILIO_SMS_FROM_NUMBER;
    else process.env.TWILIO_SMS_FROM_NUMBER = originalFrom;
  });
  const errors = t.mock.method(console, "error", () => {});

  await twilio.trySendInviteSMS({ senderUserId: "u1", senderName: "Sam", to: "+14155550100", kind: "friend" });

  assert.equal(sent.length, 0);
  const lines = errors.mock.calls.map((call) => String(call.arguments[0]));
  assert.ok(lines.some((line) => line.startsWith("[invite-sms] skipped reason=cap-check-failed")), lines.join("\n"));
  assert.ok(lines.every((line) => !line.includes("4155550100")), "full phone number must not be logged");
});
