"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { redactPhone, phoneLogKey, redactPhonesInText, describeError } = require("../../lib/redact");

function withEnv(values, fn) {
  const saved = {};
  for (const [name, value] of Object.entries(values)) {
    saved[name] = process.env[name];
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  try {
    return fn();
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
}

test("redactPhone keeps only the country code and last 4 digits", () => {
  assert.equal(redactPhone("+14155551234"), "+1•••••1234");
  assert.equal(redactPhone("+447700900123"), "+44•••••0123");
  assert.equal(redactPhone("+919876543210"), "+91•••••3210");
  assert.equal(redactPhone("+79161234567"), "+7•••••4567");
  assert.equal(redactPhone("+353861234567"), "+353•••••4567");
  assert.equal(redactPhone("+97150123456"), "+971•••••3456");
});

test("redactPhone hides the number's length", () => {
  assert.equal(redactPhone("+12345678").length, redactPhone("+123456789012345").length);
});

test("redactPhone never echoes something that isn't an E.164 number", () => {
  for (const value of ["14155551234", "+0123456", "not a phone", "", null, undefined, 42]) {
    assert.equal(redactPhone(value), "[redacted]");
  }
});

test("phoneLogKey is 12 hex characters, stable, and doesn't contain the number", () => {
  withEnv({ LOG_HASH_SECRET: "secret-a", JWT_SECRET: undefined }, () => {
    const key = phoneLogKey("+14155551234");
    assert.match(key, /^[0-9a-f]{12}$/);
    assert.equal(phoneLogKey("+14155551234"), key);
    assert.notEqual(phoneLogKey("+14155551235"), key);
    assert.ok(!key.includes("4155551234"));
  });
});

test("phoneLogKey depends on the secret and falls back to JWT_SECRET", () => {
  const a = withEnv({ LOG_HASH_SECRET: "secret-a", JWT_SECRET: undefined }, () => phoneLogKey("+14155551234"));
  const b = withEnv({ LOG_HASH_SECRET: "secret-b", JWT_SECRET: undefined }, () => phoneLogKey("+14155551234"));
  assert.notEqual(a, b);
  const viaJwt = withEnv({ LOG_HASH_SECRET: undefined, JWT_SECRET: "secret-a" }, () => phoneLogKey("+14155551234"));
  assert.equal(viaJwt, a);
});

test("phoneLogKey still works with no secret configured", () => {
  withEnv({ LOG_HASH_SECRET: undefined, JWT_SECRET: undefined }, () => {
    const key = phoneLogKey("+14155551234");
    assert.match(key, /^[0-9a-f]{12}$/);
    assert.equal(phoneLogKey("+14155551234"), key);
  });
});

test("redactPhonesInText masks numbers inside messages", () => {
  assert.equal(
    redactPhonesInText("The 'To' number +14155551234 is not a valid phone number."),
    "The 'To' number +1•••••1234 is not a valid phone number."
  );
  assert.equal(redactPhonesInText('where: { phoneNumber: "+447700900123" }'), 'where: { phoneNumber: "+44•••••0123" }');
  assert.equal(redactPhonesInText("called 4155551234 twice"), "called [number] twice");
  assert.equal(redactPhonesInText("status 404 after 3 tries"), "status 404 after 3 tries");
});

test("describeError gives name, code, status and a masked message", () => {
  const error = Object.assign(new Error("Unable to create record: The 'To' number +14155551234 is invalid"), {
    name: "RestException",
    code: 21211,
    status: 400,
  });
  const text = describeError(error);
  assert.equal(text, "RestException code=21211 status=400 Unable to create record: The 'To' number +1•••••1234 is invalid");
  assert.ok(!text.includes("4155551234"));
  assert.equal(describeError("plain +14155551234"), "plain +1•••••1234");
});
