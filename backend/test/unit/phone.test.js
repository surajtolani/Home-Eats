"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { E164_PHONE_REGEX } = require("../../lib/phone");

test("accepts a valid E.164 number", () => {
  assert.ok(E164_PHONE_REGEX.test("+14155551234"));
});

test("rejects numbers that aren't E.164", () => {
  for (const bad of ["14155551234", "+0123456", "+1 415 555 1234"]) {
    assert.equal(E164_PHONE_REGEX.test(bad), false, `${bad} should be rejected`);
  }
});
