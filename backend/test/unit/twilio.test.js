"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { inviteSMSBody } = require("../../lib/twilio");

const OPT_OUT = "Reply STOP to opt out.";

function withDownloadURL(value, fn) {
  const original = process.env.APP_DOWNLOAD_URL;
  if (value === undefined) delete process.env.APP_DOWNLOAD_URL;
  else process.env.APP_DOWNLOAD_URL = value;
  try {
    fn();
  } finally {
    if (original === undefined) delete process.env.APP_DOWNLOAD_URL;
    else process.env.APP_DOWNLOAD_URL = original;
  }
}

test("inviteSMSBody ends with the opt-out line without APP_DOWNLOAD_URL", () => {
  withDownloadURL(undefined, () => {
    const body = inviteSMSBody("Sam invited you to Home Eats.");
    assert.ok(body.endsWith(OPT_OUT), body);
    assert.ok(!body.includes("Get Home Eats:"), body);
  });
});

test("inviteSMSBody ends with the opt-out line with APP_DOWNLOAD_URL", () => {
  withDownloadURL("https://example.com/app", () => {
    const body = inviteSMSBody("Sam invited you to Home Eats.");
    assert.ok(body.endsWith(OPT_OUT), body);
    assert.ok(body.includes("Get Home Eats: https://example.com/app"), body);
  });
});

const { sanitizeNameForSMS, friendInviteSMS, groupInviteSMS } = require("../../lib/twilio");

test("sanitizeNameForSMS removes links", () => {
  assert.equal(sanitizeNameForSMS("Bob visit evil.com/x"), "Bob visit evilcomx");
  assert.equal(sanitizeNameForSMS("evil-.com"), "evil-com");
  // Full-width lookalike characters are normalized first, then stripped.
  assert.equal(sanitizeNameForSMS("ｅｖｉｌ．ｃｏｍ"), "evilcom");
  assert.equal(sanitizeNameForSMS("Bob https://evil.com"), "Bob httpsevilcom");
});

test("sanitizeNameForSMS removes digits, symbols and invisible characters", () => {
  assert.equal(sanitizeNameForSMS("Call +1 415 555 1234"), "Call");
  assert.equal(sanitizeNameForSMS("Ann‮evil"), "Annevil");
  assert.equal(sanitizeNameForSMS("x​.com"), "xcom");
});

test("sanitizeNameForSMS keeps ordinary names", () => {
  assert.equal(sanitizeNameForSMS("Zoë O'Brien-Lee"), "Zoë O'Brien-Lee");
  assert.equal(sanitizeNameForSMS("  Mary   Jane  "), "Mary Jane");
});

test("sanitizeNameForSMS falls back to 'A friend' when no letters are left", () => {
  for (const raw of ["😀😀", "", "...", "123", null, undefined]) {
    assert.equal(sanitizeNameForSMS(raw), "A friend", `input ${JSON.stringify(raw)}`);
  }
});

test("sanitizeNameForSMS removes a dot before a letter even with combining marks between", () => {
  assert.equal(sanitizeNameForSMS("evil.\u0301com"), "evil\u0301com");
});

test("sanitizeNameForSMS never splits a character when cutting to 30", () => {
  // U+20000 is a letter outside the Basic Multilingual Plane (two UTF-16 units).
  const result = sanitizeNameForSMS("a".repeat(29) + "\u{20000}\u{20000}");
  assert.equal(Array.from(result).length, 30);
  assert.equal(result, "a".repeat(29) + "\u{20000}");
  // A lone surrogate wouldn't survive a UTF-8 round trip (it becomes U+FFFD).
  assert.equal(Buffer.from(result, "utf8").toString("utf8"), result);
});

test("sanitizeNameForSMS output is at most 30 characters", () => {
  assert.equal(sanitizeNameForSMS("a".repeat(100)).length, 30);
  const long = sanitizeNameForSMS("Alexandria Catherine Montgomery-Smythe");
  assert.ok(long.length <= 30, long);
  assert.equal(long, long.trim());
});

test("friendInviteSMS and groupInviteSMS use the fixed templates", () => {
  withDownloadURL(undefined, () => {
    assert.equal(
      friendInviteSMS("Sam"),
      "Sam invited you to Home Eats, a family meal-planning app. Reply STOP to opt out."
    );
    assert.equal(
      groupInviteSMS("Sam"),
      "Sam invited you to plan meals together on Home Eats. Reply STOP to opt out."
    );
    assert.equal(
      friendInviteSMS("visit evil.com"),
      "visit evilcom invited you to Home Eats, a family meal-planning app. Reply STOP to opt out."
    );
  });
  withDownloadURL("https://example.com/app", () => {
    assert.equal(
      groupInviteSMS(null),
      "A friend invited you to plan meals together on Home Eats. Get Home Eats: https://example.com/app Reply STOP to opt out."
    );
  });
});
