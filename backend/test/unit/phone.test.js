"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { E164_PHONE_REGEX, PHONE_ERROR, normalizePhoneNumber, phoneNumberField } = require("../../lib/phone");

test("E164_PHONE_REGEX accepts a valid E.164 number", () => {
  assert.ok(E164_PHONE_REGEX.test("+14155551234"));
});

test("E164_PHONE_REGEX rejects numbers that aren't E.164", () => {
  for (const bad of ["14155551234", "+0123456", "+1 415 555 1234"]) {
    assert.equal(E164_PHONE_REGEX.test(bad), false, `${bad} should be rejected`);
  }
});

test("normalizePhoneNumber rewrites the same phone to one string", () => {
  const cases = [
    // The real incident: autofill's "+1" plus the app's own "+1".
    ["+117813633306", "+17813633306"],
    ["+17813633306", "+17813633306"],
    [" +1 (781) 363-3306 ", "+17813633306"],
    ["+1.781.363.3306", "+17813633306"],
    ["+1 781 363 3306", "+17813633306"],
    // UK, with and without the national "0" kept after the country code.
    ["+447911123456", "+447911123456"],
    ["+44 07911 123456", "+447911123456"],
    // India, Italy (landline keeps its leading 0), Australia, Jamaica (+1).
    ["+91 98765 43210", "+919876543210"],
    ["+39 06 1234 5678", "+390612345678"],
    ["+61 412 345 678", "+61412345678"],
    ["+1 876 555 1234", "+18765551234"],
  ];
  for (const [input, expected] of cases) {
    assert.equal(normalizePhoneNumber(input), expected, JSON.stringify(input));
  }
});

test("normalizePhoneNumber keeps the old rule for numbers the library doesn't recognize", () => {
  // Already E.164 but not a number libphonenumber knows: accepted unchanged,
  // exactly as before, so a missing number range can't lock anyone out.
  assert.equal(normalizePhoneNumber("+999123456789"), "+999123456789");
  // Not recognized and not plain E.164: rejected.
  assert.equal(normalizePhoneNumber("+999 123 456 789"), null);
});

test("normalizePhoneNumber rejects what isn't a single phone number", () => {
  const bad = [
    "", "   ", "+", "+1234", "+0123456789",
    "17813633306", // no "+": the server has no region to guess from
    "+1 781 363 3306 ext 5", "+17813633306x5", "call +17813633306",
    "+1781363330６", // a full-width digit
    `+${"1".repeat(40)}`,
    null, undefined, 17813633306,
  ];
  for (const input of bad) {
    assert.equal(normalizePhoneNumber(input), null, JSON.stringify(input));
  }
});

test("phoneNumberField outputs the canonical number and a clear error", () => {
  assert.deepEqual(phoneNumberField.safeParse("+117813633306"), { success: true, data: "+17813633306" });
  for (const input of ["+1234", 5]) {
    const result = phoneNumberField.safeParse(input);
    assert.equal(result.success, false);
    assert.equal(result.error.issues[0].message, PHONE_ERROR);
  }
});
